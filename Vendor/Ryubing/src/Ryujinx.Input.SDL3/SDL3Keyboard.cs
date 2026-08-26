using Ryujinx.Common.Configuration.Hid;
using Ryujinx.Common.Configuration.Hid.Keyboard;
using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Services.Hid;
using System;
using System.Collections.Generic;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Threading;
using SDL;
using static SDL.SDL3;
using ConfigPhysicalKey = Ryujinx.Common.Configuration.Hid.PhysicalKey;

namespace Ryujinx.Input.SDL3
{
    public class SDL3Keyboard : IKeyboard
    {
        private const int ExternalScancodeCount = 512;
        private const int ExternalHeldMask = 1 << 0;
        private const int ExternalPendingPressMask = 1 << 1;
        private static readonly int[] _externalKeyState = new int[ExternalScancodeCount];
        private static int _externalInputMode;
        private readonly Lock _userMappingLock = new();
        private StandardKeyboardInputConfig _configuration;
        private readonly List<KeyboardInputMappingHelper.KeyboardButtonMapping> _buttonsUserMapping;


        private static readonly SDL_Keycode[] _keysDriverMapping =
        [
            // INVALID
            SDL_Keycode.SDLK_0,
            // Presented as modifiers, so invalid here.
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,

            SDL_Keycode.SDLK_F1,
            SDL_Keycode.SDLK_F2,
            SDL_Keycode.SDLK_F3,
            SDL_Keycode.SDLK_F4,
            SDL_Keycode.SDLK_F5,
            SDL_Keycode.SDLK_F6,
            SDL_Keycode.SDLK_F7,
            SDL_Keycode.SDLK_F8,
            SDL_Keycode.SDLK_F9,
            SDL_Keycode.SDLK_F10,
            SDL_Keycode.SDLK_F11,
            SDL_Keycode.SDLK_F12,
            SDL_Keycode.SDLK_F13,
            SDL_Keycode.SDLK_F14,
            SDL_Keycode.SDLK_F15,
            SDL_Keycode.SDLK_F16,
            SDL_Keycode.SDLK_F17,
            SDL_Keycode.SDLK_F18,
            SDL_Keycode.SDLK_F19,
            SDL_Keycode.SDLK_F20,
            SDL_Keycode.SDLK_F21,
            SDL_Keycode.SDLK_F22,
            SDL_Keycode.SDLK_F23,
            SDL_Keycode.SDLK_F24,

            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_0,

            SDL_Keycode.SDLK_UP,
            SDL_Keycode.SDLK_DOWN,
            SDL_Keycode.SDLK_LEFT,
            SDL_Keycode.SDLK_RIGHT,
            SDL_Keycode.SDLK_RETURN,
            SDL_Keycode.SDLK_ESCAPE,
            SDL_Keycode.SDLK_SPACE,
            SDL_Keycode.SDLK_TAB,
            SDL_Keycode.SDLK_BACKSPACE,
            SDL_Keycode.SDLK_INSERT,
            SDL_Keycode.SDLK_DELETE,
            SDL_Keycode.SDLK_PAGEUP,
            SDL_Keycode.SDLK_PAGEDOWN,
            SDL_Keycode.SDLK_HOME,
            SDL_Keycode.SDLK_END,
            SDL_Keycode.SDLK_CAPSLOCK,
            SDL_Keycode.SDLK_SCROLLLOCK,
            SDL_Keycode.SDLK_PRINTSCREEN,
            SDL_Keycode.SDLK_PAUSE,
            SDL_Keycode.SDLK_NUMLOCKCLEAR,
            SDL_Keycode.SDLK_CLEAR,
            SDL_Keycode.SDLK_KP_0,
            SDL_Keycode.SDLK_KP_1,
            SDL_Keycode.SDLK_KP_2,
            SDL_Keycode.SDLK_KP_3,
            SDL_Keycode.SDLK_KP_4,
            SDL_Keycode.SDLK_KP_5,
            SDL_Keycode.SDLK_KP_6,
            SDL_Keycode.SDLK_KP_7,
            SDL_Keycode.SDLK_KP_8,
            SDL_Keycode.SDLK_KP_9,
            SDL_Keycode.SDLK_KP_DIVIDE,
            SDL_Keycode.SDLK_KP_MULTIPLY,
            SDL_Keycode.SDLK_KP_MINUS,
            SDL_Keycode.SDLK_KP_PLUS,
            SDL_Keycode.SDLK_KP_DECIMAL,
            SDL_Keycode.SDLK_KP_ENTER,
            SDL_Keycode.SDLK_A,
            SDL_Keycode.SDLK_B,
            SDL_Keycode.SDLK_C,
            SDL_Keycode.SDLK_D,
            SDL_Keycode.SDLK_E,
            SDL_Keycode.SDLK_F,
            SDL_Keycode.SDLK_G,
            SDL_Keycode.SDLK_H,
            SDL_Keycode.SDLK_I,
            SDL_Keycode.SDLK_J,
            SDL_Keycode.SDLK_K,
            SDL_Keycode.SDLK_L,
            SDL_Keycode.SDLK_M,
            SDL_Keycode.SDLK_N,
            SDL_Keycode.SDLK_O,
            SDL_Keycode.SDLK_P,
            SDL_Keycode.SDLK_Q,
            SDL_Keycode.SDLK_R,
            SDL_Keycode.SDLK_S,
            SDL_Keycode.SDLK_T,
            SDL_Keycode.SDLK_U,
            SDL_Keycode.SDLK_V,
            SDL_Keycode.SDLK_W,
            SDL_Keycode.SDLK_X,
            SDL_Keycode.SDLK_Y,
            SDL_Keycode.SDLK_Z,
            SDL_Keycode.SDLK_0,
            SDL_Keycode.SDLK_1,
            SDL_Keycode.SDLK_2,
            SDL_Keycode.SDLK_3,
            SDL_Keycode.SDLK_4,
            SDL_Keycode.SDLK_5,
            SDL_Keycode.SDLK_6,
            SDL_Keycode.SDLK_7,
            SDL_Keycode.SDLK_8,
            SDL_Keycode.SDLK_9,
            SDL_Keycode.SDLK_GRAVE,
            SDL_Keycode.SDLK_GRAVE,
            SDL_Keycode.SDLK_MINUS,
            SDL_Keycode.SDLK_PLUS,
            SDL_Keycode.SDLK_LEFTBRACKET,
            SDL_Keycode.SDLK_RIGHTBRACKET,
            SDL_Keycode.SDLK_SEMICOLON,
            SDL_Keycode.SDLK_APOSTROPHE,
            SDL_Keycode.SDLK_COMMA,
            SDL_Keycode.SDLK_PERIOD,
            SDL_Keycode.SDLK_SLASH,
            SDL_Keycode.SDLK_BACKSLASH,

            // Invalids
            SDL_Keycode.SDLK_0
        ];

        public SDL3Keyboard(string id, string name)
        {
            Id = id;
            Name = name;
            _buttonsUserMapping = [];
        }

        private bool HasConfiguration => _configuration != null;

        public string Id { get; }

        public string Name { get; }

        public bool IsConnected => true;

        public GamepadFeaturesFlag Features => GamepadFeaturesFlag.None;

        public void Dispose()
        {
            // No operations
        }

        public static bool SetExternalKeyState(int scancode, bool pressed)
        {
            if ((uint)scancode >= ExternalScancodeCount)
            {
                return false;
            }

            ref int state = ref _externalKeyState[scancode];
            while (true)
            {
                int current = Volatile.Read(ref state);
                int next;
                if (pressed)
                {
                    // Preserve one rising edge until a keyboard snapshot
                    // observes it. AppKit can deliver a complete down/up tap
                    // between two guest input polls; a level-only bridge would
                    // otherwise lose the press entirely. Repeats while held do
                    // not re-arm the latch.
                    if ((current & ExternalHeldMask) != 0)
                    {
                        return true;
                    }
                    next = current |
                        ExternalHeldMask |
                        ExternalPendingPressMask;
                }
                else
                {
                    next = current & ~ExternalHeldMask;
                }

                if (Interlocked.CompareExchange(ref state, next, current) ==
                    current)
                {
                    return true;
                }
            }
        }

        public static void ClearExternalKeyState()
        {
            Array.Clear(_externalKeyState);
        }

        /// <summary>
        /// Makes the native host's explicit key bridge the sole keyboard state
        /// source. Embedded Cocoa windows can otherwise report the same key
        /// through both AppKit and SDL; if SDL misses one release edge, OR-ing
        /// those states leaves movement held after the physical key is up.
        /// </summary>
        public static void SetExternalInputMode(bool enabled)
        {
            // Clear on both transitions so a state from the previous owner can
            // never bleed into a new embedded session or standalone window.
            ClearExternalKeyState();
            Volatile.Write(ref _externalInputMode, enabled ? 1 : 0);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static bool ConsumeExternalKeyPressed(int scancode)
        {
            if ((uint)scancode >= ExternalScancodeCount)
            {
                return false;
            }

            ref int state = ref _externalKeyState[scancode];
            while (true)
            {
                int current = Volatile.Read(ref state);
                bool pressed = (current &
                    (ExternalHeldMask | ExternalPendingPressMask)) != 0;
                int next = current & ~ExternalPendingPressMask;
                if (Interlocked.CompareExchange(ref state, next, current) ==
                    current)
                {
                    return pressed;
                }
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private unsafe static int ToSDL3Scancode(ConfigPhysicalKey key)
        {
            if (key is >= ConfigPhysicalKey.Unknown and <= ConfigPhysicalKey.Menu)
            {
                return -1;
            }

            return (int)SDL_GetScancodeFromKey(_keysDriverMapping[(int)key], null);
        }

        private static SDL_Keymod GetKeyboardModifierMask(ConfigPhysicalKey key)
        {
            return key switch
            {
                ConfigPhysicalKey.ShiftLeft => SDL_Keymod.SDL_KMOD_LSHIFT,
                ConfigPhysicalKey.ShiftRight => SDL_Keymod.SDL_KMOD_RSHIFT,
                ConfigPhysicalKey.ControlLeft => SDL_Keymod.SDL_KMOD_LCTRL,
                ConfigPhysicalKey.ControlRight => SDL_Keymod.SDL_KMOD_RCTRL,
                ConfigPhysicalKey.AltLeft => SDL_Keymod.SDL_KMOD_LALT,
                ConfigPhysicalKey.AltRight => SDL_Keymod.SDL_KMOD_RALT,
                ConfigPhysicalKey.WinLeft => SDL_Keymod.SDL_KMOD_LGUI,
                ConfigPhysicalKey.WinRight => SDL_Keymod.SDL_KMOD_RGUI,
                // NOTE: Menu key isn't supported by SDL3.
                _ => SDL_Keymod.SDL_KMOD_NONE
            };
        }

        private static int GetExternalModifierScancode(ConfigPhysicalKey key)
        {
            return key switch
            {
                ConfigPhysicalKey.ControlLeft => 224,
                ConfigPhysicalKey.ShiftLeft => 225,
                ConfigPhysicalKey.AltLeft => 226,
                ConfigPhysicalKey.WinLeft => 227,
                ConfigPhysicalKey.ControlRight => 228,
                ConfigPhysicalKey.ShiftRight => 229,
                ConfigPhysicalKey.AltRight => 230,
                ConfigPhysicalKey.WinRight => 231,
                _ => -1,
            };
        }

        public unsafe KeyboardStateSnapshot GetKeyboardStateSnapshot()
        {
            bool externalInputMode = Volatile.Read(ref _externalInputMode) != 0;
            SDLBool* rawKeyboardState = null;
            SDL_Keymod rawKeyboardModifierState = SDL_Keymod.SDL_KMOD_NONE;

            if (!externalInputMode)
            {
                rawKeyboardState = SDL_GetKeyboardState(null);
                rawKeyboardModifierState = SDL_GetModState();
            }

            bool[] keysState = new bool[(int)ConfigPhysicalKey.Count];

            for (ConfigPhysicalKey key = 0; key < ConfigPhysicalKey.Count; key++)
            {
                int index = ToSDL3Scancode(key);
                if (index == -1)
                {
                    SDL_Keymod modifierMask = GetKeyboardModifierMask(key);

                    if (modifierMask == SDL_Keymod.SDL_KMOD_NONE)
                    {
                        continue;
                    }

                    int externalScancode = GetExternalModifierScancode(key);
                    keysState[(int)key] =
                        ConsumeExternalKeyPressed(externalScancode) ||
                        (!externalInputMode &&
                            (rawKeyboardModifierState & modifierMask) == modifierMask);
                }
                else
                {
                    keysState[(int)key] =
                        ConsumeExternalKeyPressed(index) ||
                        (!externalInputMode && rawKeyboardState[index]);
                }
            }

            return new KeyboardStateSnapshot(keysState);
        }

        private static float ConvertRawStickValue(short value)
        {
            const float ConvertRate = 1.0f / (short.MaxValue + 0.5f);

            return value * ConvertRate;
        }

        public GamepadStateSnapshot GetMappedStateSnapshot()
        {
            KeyboardStateSnapshot rawState = GetKeyboardStateSnapshot();
            GamepadStateSnapshot result = default;

            lock (_userMappingLock)
            {
                if (!HasConfiguration)
                {
                    return result;
                }

                foreach (KeyboardInputMappingHelper.KeyboardButtonMapping entry in _buttonsUserMapping)
                {
                    if (!entry.IsValid)
                    {
                        continue;
                    }

                    // Do not touch state of button already pressed
                    if (!result.IsPressed(entry.To))
                    {
                        result.SetPressed(entry.To, rawState.IsPressed(entry.From));
                    }
                }

                (short leftStickX, short leftStickY) = KeyboardInputMappingHelper.GetStickValues(ref rawState, _configuration.LeftJoyconStick);
                (short rightStickX, short rightStickY) = KeyboardInputMappingHelper.GetStickValues(ref rawState, _configuration.RightJoyconStick);

                result.SetStick(StickInputId.Left, ConvertRawStickValue(leftStickX), ConvertRawStickValue(leftStickY));
                result.SetStick(StickInputId.Right, ConvertRawStickValue(rightStickX), ConvertRawStickValue(rightStickY));
            }

            return result;
        }

        public GamepadStateSnapshot GetStateSnapshot()
        {
            throw new NotSupportedException();
        }

        public (float, float) GetStick(StickInputId inputId)
        {
            throw new NotSupportedException();
        }

        public bool IsPressed(GamepadButtonInputId inputId)
        {
            throw new NotSupportedException();
        }

        public bool IsPressed(Key key)
        {
            // We only implement GetKeyboardStateSnapshot.
            throw new NotSupportedException();
        }

        public void SetConfiguration(InputConfig configuration)
        {
            lock (_userMappingLock)
            {
                _configuration = (StandardKeyboardInputConfig)configuration;

                _buttonsUserMapping.Clear();

                _buttonsUserMapping.AddRange(KeyboardInputMappingHelper.BuildButtonMappings(_configuration));
            }
        }

        public void SetLed(uint packedRgb)
        {
            Logger.Debug?.Print(LogClass.UI, "SetLed called on an SDL3Keyboard");
        }

        public void SetTriggerThreshold(float triggerThreshold)
        {
            // No operations
        }

        public bool HDRumble(VibrationValue left, VibrationValue right)
        {
            return false;
        }
        
        public bool Rumble(float lowFrequency, float highFrequency, uint durationMs)
        {
            return false;
        }

        public Vector3 GetMotionData(MotionInputId inputId)
        {
            // No operations

            return Vector3.Zero;
        }
    }
}
