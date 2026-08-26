#nullable enable

using Ryujinx.Common.Configuration;
using Ryujinx.Input.HLE;
using Ryujinx.SDL3.Common;
using SDL;

namespace Ryujinx.Headless;

/// <summary>
/// SDL/AppKit host shell for the opt-in native SolMetal GAL bring-up path.
/// It deliberately owns no Vulkan surface.
/// </summary>
internal sealed class SolMetalWindow : WindowBase
{
    public SolMetalWindow(
        InputManager inputManager,
        GraphicsDebugLevel graphicsDebugLevel,
        AspectRatio aspectRatio,
        bool enableMouse,
        HideCursorMode hideCursorMode,
        bool ignoreControllerApplet
    ) : base(
        inputManager,
        graphicsDebugLevel,
        aspectRatio,
        enableMouse,
        hideCursorMode,
        ignoreControllerApplet
    )
    {
    }

    public override SDL_WindowFlags WindowFlags => 0;

    protected override void InitializeWindowRenderer() { }

    protected override void InitializeRenderer()
    {
        int width = IsExclusiveFullscreen ? ExclusiveFullscreenWidth : Width;
        int height = IsExclusiveFullscreen ? ExclusiveFullscreenHeight : Height;
        Renderer?.Window.SetSize(width, height);
        MouseDriver.SetClientSize(width, height);
    }

    protected override void FinalizeWindowRenderer()
    {
        if (!NativeEmbeddedEntrypoint.IsEmbedded)
        {
            Device.DisposeGpu();
        }
    }

    protected override void SwapBuffers() { }
}
