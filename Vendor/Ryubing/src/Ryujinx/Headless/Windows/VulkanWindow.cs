using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Ryujinx.Input.HLE;
using Ryujinx.SDL3.Common;
using Silk.NET.Vulkan;
using Silk.NET.Vulkan.Extensions.EXT;
using Silk.NET.Vulkan.Extensions.KHR;
using System;
using SDL;
using static SDL.SDL3;
using System.Runtime.InteropServices;

namespace Ryujinx.Headless
{
    class VulkanWindow : WindowBase
    {
        public VulkanWindow(
            InputManager inputManager,
            GraphicsDebugLevel glLogLevel,
            AspectRatio aspectRatio,
            bool enableMouse,
            HideCursorMode hideCursorMode,
            bool ignoreControllerApplet)
            : base(inputManager, glLogLevel, aspectRatio, enableMouse, hideCursorMode, ignoreControllerApplet)
        {
        }

        public override SDL_WindowFlags WindowFlags => SDL_WindowFlags.SDL_WINDOW_VULKAN;

        protected override void InitializeWindowRenderer() { }

        protected override void InitializeRenderer()
        {
            if (IsExclusiveFullscreen)
            {
                Renderer?.Window.SetSize(ExclusiveFullscreenWidth, ExclusiveFullscreenHeight);
                MouseDriver.SetClientSize(ExclusiveFullscreenWidth, ExclusiveFullscreenHeight);
            }
            else
            {
                Renderer?.Window.SetSize(Width, Height);
                MouseDriver.SetClientSize(Width, Height);
            }
        }

        public unsafe nint CreateWindowSurface(Instance instance, Vk api)
        {
            if (NativeEmbeddedEntrypoint.IsEmbedded)
            {
                if (!api.TryGetInstanceExtension(instance, out ExtMetalSurface metalSurfaceApi))
                {
                    throw new InvalidOperationException("VK_EXT_metal_surface is unavailable.");
                }

                MetalSurfaceCreateInfoEXT createInfo = new()
                {
                    SType = StructureType.MetalSurfaceCreateInfoExt,
                    PLayer = (nint*)NativeEmbeddedEntrypoint.MetalLayer,
                };

                Result result = metalSurfaceApi.CreateMetalSurface(
                    instance,
                    in createInfo,
                    null,
                    out SurfaceKHR metalSurface
                );
                if (result != Result.Success)
                {
                    throw new InvalidOperationException($"vkCreateMetalSurfaceEXT failed with {result}.");
                }

                return (nint)metalSurface.Handle;
            }

            VkSurfaceKHR_T surface = new();
            VkSurfaceKHR_T* surfaceHandle = &surface;
            VkSurfaceKHR_T** surfaceHandleHandle = &surfaceHandle;

            void CreateSurface()
            {
                if (!SDL_Vulkan_CreateSurface(WindowHandle, (VkInstance_T*)instance.Handle, null, surfaceHandleHandle))
                {
                    string errorMessage = $"SDL_Vulkan_CreateSurface failed with error \"{SDL_GetError()}\"";

                    Logger.Error?.Print(LogClass.Application, errorMessage);

                    throw new Exception(errorMessage);
                }
            }

            if (SDL3Driver.MainThreadDispatcher != null)
            {
                SDL3Driver.MainThreadDispatcher(CreateSurface);
            }
            else
            {
                CreateSurface();
            }

            return (nint)surfaceHandle;
        }

        public unsafe static string[] GetRequiredInstanceExtensions()
        {
            if (NativeEmbeddedEntrypoint.IsEmbedded)
            {
                return [KhrSurface.ExtensionName, ExtMetalSurface.ExtensionName];
            }

            uint extensionCount = 0;
            byte** extensions = SDL_Vulkan_GetInstanceExtensions(&extensionCount);
            if (extensionCount == 0) {
                string errorMessage = $"SDL_Vulkan_GetInstanceExtensions failed with error \"{SDL_GetError()}\"";

                Logger.Error?.Print(LogClass.Application, errorMessage);

                throw new Exception(errorMessage);
            }
            string[] extensionArr = new string[extensionCount];
            for (int i = 0; i < extensionCount; i++) {
                extensionArr[i] = Marshal.PtrToStringUTF8((nint)extensions[i]);
            }
            return extensionArr;
        }

        protected override void FinalizeWindowRenderer()
        {
            Device.DisposeGpu();
        }

        protected override void SwapBuffers() { }
    }
}
