/* Windows-side controller probe. Run in an isolated, app-owned probe folder;
 * never copies files into a game or changes its controller configuration. */
#define COBJMACROS
#define DIRECTINPUT_VERSION 0x0800
#include <windows.h>
#include <xinput.h>
#include <dinput.h>
#include <roapi.h>
#include <winstring.h>
#include <initguid.h>
#define WIDL_using_Windows_Gaming_Input
#include <windows.gaming.input.h>
#include <stdio.h>
#include <wchar.h>

typedef DWORD (WINAPI *get_state_fn)(DWORD, XINPUT_STATE *);
typedef DWORD (WINAPI *get_caps_fn)(DWORD, DWORD, XINPUT_CAPABILITIES *);
static const wchar_t *names[] = {L"xinput1_3.dll", L"xinput1_4.dll", L"xinput9_1_0.dll", L"xinput1_2.dll", L"xinput1_1.dll"};
static HMODULE modules[5];
static get_state_fn read_state[5];
static get_caps_fn read_caps[5];
static wchar_t text[4096];
static FILE *log_file;
static ULONGLONG started;
static IGamepadStatics *wgi;

static void initialize_wgi(void) {
    HSTRING name;
    RoInitialize(RO_INIT_MULTITHREADED);
    WindowsCreateString(L"Windows.Gaming.Input.Gamepad", 28, &name);
    HRESULT result = RoGetActivationFactory(name, &IID_IGamepadStatics, (void **)&wgi);
    fwprintf(log_file, L"wgi-activation=%08lx\n", (unsigned long)result);
    WindowsDeleteString(name);
}

static void sample_wgi(void) {
    if (!wgi) return;
    __FIVectorView_1_Windows__CGaming__CInput__CGamepad *list = NULL;
    HRESULT result = IGamepadStatics_get_Gamepads(wgi, &list);
    unsigned count = 0;
    if (SUCCEEDED(result) && list) {
        __FIVectorView_1_Windows__CGaming__CInput__CGamepad_get_Size(list, &count);
        fwprintf(log_file, L"wgi-count=%u\n", count);
        if (count) {
            IGamepad *pad = NULL; GamepadReading reading = {0};
            __FIVectorView_1_Windows__CGaming__CInput__CGamepad_GetAt(list, 0, &pad);
            if (pad) {
                result = IGamepad_GetCurrentReading(pad, &reading);
                fwprintf(log_file, L"wgi-reading=%08lx buttons=%x triggers=%f,%f sticks=%f,%f,%f,%f\n",
                         (unsigned long)result, reading.Buttons, reading.LeftTrigger, reading.RightTrigger,
                         reading.LeftThumbstickX, reading.LeftThumbstickY, reading.RightThumbstickX, reading.RightThumbstickY);
                IGamepad_Release(pad);
            }
        }
        __FIVectorView_1_Windows__CGaming__CInput__CGamepad_Release(list);
    } else { fwprintf(log_file, L"wgi-list=%08lx\n", (unsigned long)result); }
}

static BOOL CALLBACK joystick(const DIDEVICEINSTANCEW *device, void *context) {
    (void)context;
    fwprintf(log_file, L"directinput-device name=%ls type=%lu\n", device->tszProductName, device->dwDevType);
    return DIENUM_CONTINUE;
}

static void enumerate_directinput(void) {
    HMODULE module = LoadLibraryW(L"dinput8.dll");
    typedef HRESULT (WINAPI *create_fn)(HINSTANCE, DWORD, REFIID, void **, IUnknown *);
    create_fn create = module ? (create_fn)GetProcAddress(module, "DirectInput8Create") : NULL;
    LPDIRECTINPUT8W input = NULL;
    HRESULT result = create ? create(GetModuleHandleW(NULL), 0x0800, &IID_IDirectInput8W, (void **)&input, NULL) : E_NOINTERFACE;
    fwprintf(log_file, L"directinput-create=%08lx\n", (unsigned long)result);
    if (SUCCEEDED(result)) {
        result = IDirectInput8_EnumDevices(input, DI8DEVCLASS_GAMECTRL, joystick, NULL, DIEDFL_ATTACHEDONLY);
        fwprintf(log_file, L"directinput-enumerate=%08lx\n", (unsigned long)result);
        IDirectInput8_Release(input);
    }
}

static void sample(HWND window) {
    wchar_t *out = text;
    size_t remaining = sizeof(text) / sizeof(text[0]);
    int count = swprintf(out, remaining, L"Windows XInput check — press buttons and move sticks\n\n");
    out += count; remaining -= count;
    for (unsigned i = 0; i < 5; ++i) {
        XINPUT_STATE state = {0}; XINPUT_CAPABILITIES caps = {0};
        DWORD status = read_state[i] ? read_state[i](0, &state) : ERROR_PROC_NOT_FOUND;
        DWORD capability = read_caps[i] ? read_caps[i](0, XINPUT_FLAG_GAMEPAD, &caps) : ERROR_PROC_NOT_FOUND;
        fwprintf(log_file, L"t=%llu dll=%ls state=%lu caps=%lu packet=%lu buttons=%04x triggers=%u,%u sticks=%d,%d,%d,%d foreground=%d\n",
                 GetTickCount64() - started, names[i], status, capability, state.dwPacketNumber,
                 state.Gamepad.wButtons, state.Gamepad.bLeftTrigger, state.Gamepad.bRightTrigger,
                 state.Gamepad.sThumbLX, state.Gamepad.sThumbLY, state.Gamepad.sThumbRX, state.Gamepad.sThumbRY,
                 GetForegroundWindow() == window);
        count = swprintf(out, remaining, L"%ls: %ls (error %lu)\nButtons %04x    LT %u RT %u    L %d,%d R %d,%d\n\n", names[i],
                         status == ERROR_SUCCESS ? L"CONNECTED" : L"not connected", status, state.Gamepad.wButtons,
                         state.Gamepad.bLeftTrigger, state.Gamepad.bRightTrigger, state.Gamepad.sThumbLX,
                         state.Gamepad.sThumbLY, state.Gamepad.sThumbRX, state.Gamepad.sThumbRY);
        if (count > 0) { out += count; remaining -= count; }
    }
    sample_wgi();
    fflush(log_file);
    InvalidateRect(window, NULL, TRUE);
    if (GetTickCount64() - started > 45000) DestroyWindow(window);
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_TIMER) { sample(window); return 0; }
    if (message == WM_PAINT) {
        PAINTSTRUCT paint; HDC dc = BeginPaint(window, &paint);
        RECT rect; GetClientRect(window, &rect); rect.left += 20; rect.top += 20;
        SetBkMode(dc, TRANSPARENT);
        DrawTextW(dc, text, -1, &rect, DT_LEFT | DT_TOP | DT_NOPREFIX);
        EndPaint(window, &paint); return 0;
    }
    if (message == WM_DESTROY) { KillTimer(window, 1); PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command, int show) {
    (void)previous; (void)command; (void)show;
    log_file = _wfopen(L"gamepad-probe.txt", L"w");
    if (!log_file) return 2;
    started = GetTickCount64();
    for (unsigned i = 0; i < 5; ++i) {
        modules[i] = LoadLibraryW(names[i]);
        fwprintf(log_file, L"load %ls success=%d error=%lu\n", names[i], modules[i] != NULL, GetLastError());
        if (modules[i]) {
            read_state[i] = (get_state_fn)GetProcAddress(modules[i], "XInputGetState");
            read_caps[i] = (get_caps_fn)GetProcAddress(modules[i], "XInputGetCapabilities");
        }
    }
    enumerate_directinput();
    initialize_wgi();
    WNDCLASSW cls = {0}; cls.lpfnWndProc = window_proc; cls.hInstance = instance;
    cls.lpszClassName = L"WineVisionGamepadProbe"; cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassW(&cls);
    HWND window = CreateWindowW(cls.lpszClassName, L"Windows controller input check", WS_OVERLAPPEDWINDOW,
                                0, 0, 1100, 700, NULL, NULL, instance, NULL);
    if (!window) return 3;
    ShowWindow(window, SW_SHOW); SetForegroundWindow(window);
    SetTimer(window, 1, 250, NULL); sample(window);
    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
    fclose(log_file);
    return 0;
}
