/* A Windows x64 ANGLE/D3D11 pixel probe, independent of Godot and CoreCLR.
 * Build with the pinned official ANGLE headers; DLLs are loaded side by side. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

static FILE *journal;
static HMODULE egl_module, gl_module;
static void note(const char *format, ...)
{
    char line[1024];
    va_list args;
    va_start(args, format); vsnprintf(line, sizeof(line), format, args); va_end(args);
    if (journal) { fprintf(journal, "%s\n", line); fflush(journal); }
    OutputDebugStringA(line);
}

#define EGL_FUNCTIONS(X) \
    X(PFNEGLGETPROCADDRESSPROC, eglGetProcAddress) X(PFNEGLINITIALIZEPROC, eglInitialize) \
    X(PFNEGLBINDAPIPROC, eglBindAPI) X(PFNEGLCHOOSECONFIGPROC, eglChooseConfig) \
    X(PFNEGLGETCONFIGATTRIBPROC, eglGetConfigAttrib) \
    X(PFNEGLCREATECONTEXTPROC, eglCreateContext) X(PFNEGLCREATEWINDOWSURFACEPROC, eglCreateWindowSurface) \
    X(PFNEGLMAKECURRENTPROC, eglMakeCurrent) X(PFNEGLSWAPBUFFERSPROC, eglSwapBuffers) \
    X(PFNEGLQUERYSURFACEPROC, eglQuerySurface) X(PFNEGLGETERRORPROC, eglGetError) \
    X(PFNEGLDESTROYSURFACEPROC, eglDestroySurface) X(PFNEGLDESTROYCONTEXTPROC, eglDestroyContext) \
    X(PFNEGLTERMINATEPROC, eglTerminate)
#define GL_FUNCTIONS(X) \
    X(PFNGLGETSTRINGPROC, glGetString) X(PFNGLGETERRORPROC, glGetError) \
    X(PFNGLCLEARCOLORPROC, glClearColor) X(PFNGLCLEARPROC, glClear) X(PFNGLVIEWPORTPROC, glViewport) \
    X(PFNGLREADPIXELSPROC, glReadPixels) X(PFNGLCREATESHADERPROC, glCreateShader) \
    X(PFNGLSHADERSOURCEPROC, glShaderSource) X(PFNGLCOMPILESHADERPROC, glCompileShader) \
    X(PFNGLGETSHADERIVPROC, glGetShaderiv) X(PFNGLGETSHADERINFOLOGPROC, glGetShaderInfoLog) \
    X(PFNGLCREATEPROGRAMPROC, glCreateProgram) X(PFNGLATTACHSHADERPROC, glAttachShader) \
    X(PFNGLLINKPROGRAMPROC, glLinkProgram) X(PFNGLGETPROGRAMIVPROC, glGetProgramiv) \
    X(PFNGLGETPROGRAMINFOLOGPROC, glGetProgramInfoLog) X(PFNGLUSEPROGRAMPROC, glUseProgram) \
    X(PFNGLGENTEXTURESPROC, glGenTextures) X(PFNGLBINDTEXTUREPROC, glBindTexture) \
    X(PFNGLTEXIMAGE2DPROC, glTexImage2D) X(PFNGLTEXPARAMETERIPROC, glTexParameteri) \
    X(PFNGLCOMPRESSEDTEXIMAGE2DPROC, glCompressedTexImage2D) \
    X(PFNGLENABLEPROC, glEnable) X(PFNGLDISABLEPROC, glDisable) \
    X(PFNGLBLENDFUNCSEPARATEPROC, glBlendFuncSeparate) X(PFNGLDRAWARRAYSPROC, glDrawArrays) \
    X(PFNGLGETUNIFORMLOCATIONPROC, glGetUniformLocation) X(PFNGLUNIFORM1IPROC, glUniform1i) \
    X(PFNGLGENBUFFERSPROC, glGenBuffers) X(PFNGLBINDBUFFERPROC, glBindBuffer) \
    X(PFNGLBUFFERDATAPROC, glBufferData) X(PFNGLBUFFERSUBDATAPROC, glBufferSubData) \
    X(PFNGLBINDBUFFERBASEPROC, glBindBufferBase) X(PFNGLDELETEBUFFERSPROC, glDeleteBuffers) \
    X(PFNGLGETUNIFORMBLOCKINDEXPROC, glGetUniformBlockIndex) X(PFNGLUNIFORMBLOCKBINDINGPROC, glUniformBlockBinding) \
    X(PFNGLGENFRAMEBUFFERSPROC, glGenFramebuffers) X(PFNGLBINDFRAMEBUFFERPROC, glBindFramebuffer) \
    X(PFNGLFRAMEBUFFERTEXTURE2DPROC, glFramebufferTexture2D) X(PFNGLCHECKFRAMEBUFFERSTATUSPROC, glCheckFramebufferStatus) \
    X(PFNGLDELETEFRAMEBUFFERSPROC, glDeleteFramebuffers) \
    X(PFNGLDELETEPROGRAMPROC, glDeleteProgram) X(PFNGLDELETESHADERPROC, glDeleteShader) \
    X(PFNGLDELETETEXTURESPROC, glDeleteTextures)
#define DECLARE(type, name) static type p_##name;
EGL_FUNCTIONS(DECLARE)
GL_FUNCTIONS(DECLARE)

static int load_functions(void)
{
    /* LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR requires an absolute path. */
    WCHAR path[32768];
    if (!GetModuleFileNameW(NULL, path, 32768)) return 0;
    WCHAR *tail = wcsrchr(path, L'\\');
    if (!tail) return 0;
    wcscpy(tail + 1, L"libEGL.dll");
    egl_module = LoadLibraryExW(path, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    wcscpy(tail + 1, L"libGLESv2.dll");
    gl_module = LoadLibraryExW(path, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!egl_module || !gl_module) { note("FAIL stage=load-dll win32=%lu", GetLastError()); return 0; }
#define LOAD_EGL(type, name) p_##name = (type)(uintptr_t)GetProcAddress(egl_module, #name); \
    if (!p_##name) { note("FAIL missing=%s", #name); return 0; }
#define LOAD_GL(type, name) p_##name = (type)(uintptr_t)GetProcAddress(gl_module, #name); \
    if (!p_##name) { note("FAIL missing=%s", #name); return 0; }
    EGL_FUNCTIONS(LOAD_EGL)
    GL_FUNCTIONS(LOAD_GL)
    return 1;
}

static GLuint shader(GLenum stage, const char *source)
{
    GLuint result = p_glCreateShader(stage);
    GLint okay = 0;
    p_glShaderSource(result, 1, &source, NULL); p_glCompileShader(result);
    p_glGetShaderiv(result, GL_COMPILE_STATUS, &okay);
    if (!okay) {
        char log[768]; p_glGetShaderInfoLog(result, sizeof(log), NULL, log);
        note("FAIL stage=compile shader=%u message=%s", stage, log);
        p_glDeleteShader(result); return 0;
    }
    return result;
}

static int draw_and_check(GLuint program, GLint mode, int point, int width, int height)
{
    unsigned char pixel[4] = {0};
    p_glViewport(0, 0, width, height);
    p_glClearColor(1, 0, 0, 1); p_glClear(GL_COLOR_BUFFER_BIT);
    p_glUseProgram(program); p_glUniform1i(mode, point);
    p_glEnable(GL_BLEND);
    p_glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    p_glDrawArrays(point ? GL_POINTS : GL_TRIANGLES, 0, point ? 1 : 3);
    p_glReadPixels(width / 2, height / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    GLenum error = p_glGetError();
    note("PIXEL primitive=%s size=%dx%d rgba=%u,%u,%u,%u error=0x%x", point ? "point" : "triangle",
         width, height, pixel[0], pixel[1], pixel[2], pixel[3], error);
    return error == GL_NO_ERROR && pixel[0] >= 125 && pixel[0] <= 130 && pixel[1] <= 2 &&
           pixel[2] >= 125 && pixel[2] <= 130 && pixel[3] >= 253;
}

/* Queue several frames between readbacks. Per-draw readback alone serializes
 * the GPU and can hide dynamic-uniform renaming or render-target hazards.
 * Alternate normal/inverse intermediate colors, then undo the transform: the
 * final image must stay the same through both framebuffer and program changes.
 */
static int asynchronous_postprocess(EGLDisplay display, EGLSurface surface, GLuint vs, GLuint display_program)
{
    GLuint fs = 0, program = 0, ubo = 0, textures[3] = {0}, targets[2] = {0};
    int passed = 0;
    fs = shader(GL_FRAGMENT_SHADER, "#version 300 es\nprecision highp float; uniform sampler2D image;"
        "layout(std140) uniform Transform { vec4 tint; vec4 bias; };"
        "out vec4 color; void main(){ color=texture(image,vec2(.5))*tint+bias; }");
    if (!fs) goto done;
    program = p_glCreateProgram(); p_glAttachShader(program, vs); p_glAttachShader(program, fs);
    p_glLinkProgram(program);
    GLint linked = 0; p_glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) { note("FAIL stage=postprocess-link"); goto done; }
    GLuint block = p_glGetUniformBlockIndex(program, "Transform");
    if (block == GL_INVALID_INDEX) goto done;
    p_glUniformBlockBinding(program, block, 0);
    p_glGenBuffers(1, &ubo); p_glBindBuffer(GL_UNIFORM_BUFFER, ubo);
    p_glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo);
    p_glGenTextures(3, textures); p_glGenFramebuffers(2, targets);
    const unsigned char reference[4] = {64, 128, 192, 255};
    for (unsigned i = 0; i < 3; ++i) {
        p_glBindTexture(GL_TEXTURE_2D, textures[i]);
        p_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, i ? 256 : 1, i ? 256 : 1,
                      0, GL_RGBA, GL_UNSIGNED_BYTE, i ? NULL : reference);
        p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        if (i) {
            p_glBindFramebuffer(GL_FRAMEBUFFER, targets[i - 1]);
            p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textures[i], 0);
            if (p_glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) goto done;
        }
    }
    p_glDisable(GL_BLEND);
    for (unsigned frame = 0; frame < 160; ++frame) {
        float sign = (frame & 1) ? -1.0f : 1.0f;
        float offset = (frame & 1) ? 1.0f : 0.0f;
        float transform[8] = {sign, sign, sign, 1, offset, offset, offset, 0};
        for (unsigned pass = 0; pass < 2; ++pass) {
            p_glBindFramebuffer(GL_FRAMEBUFFER, targets[pass]);
            p_glViewport(0, 0, 256, 256);
            p_glUseProgram(program);
            p_glBindBuffer(GL_UNIFORM_BUFFER, ubo);
            p_glBufferData(GL_UNIFORM_BUFFER, sizeof(transform), NULL, GL_DYNAMIC_DRAW);
            p_glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(transform), transform);
            p_glBindTexture(GL_TEXTURE_2D, textures[pass]);
            p_glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        p_glBindFramebuffer(GL_FRAMEBUFFER, 0);
        EGLint width, height;
        if (!p_eglQuerySurface(display, surface, EGL_WIDTH, &width) ||
            !p_eglQuerySurface(display, surface, EGL_HEIGHT, &height)) goto done;
        p_glViewport(0, 0, width, height);
        p_glUseProgram(display_program);
        p_glBindTexture(GL_TEXTURE_2D, textures[2]);
        p_glDrawArrays(GL_TRIANGLES, 0, 3);
        if (frame % 15 == 14 || frame == 159) {
            unsigned char pixel[4] = {0};
            p_glReadPixels(width / 2, height / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
            GLenum error = p_glGetError();
            note("PIXEL async-postprocess frame=%u rgba=%u,%u,%u,%u error=0x%x", frame,
                 pixel[0], pixel[1], pixel[2], pixel[3], error);
            for (unsigned c = 0; c < 4; ++c)
                if (abs((int)pixel[c] - reference[c]) > 2) goto done;
            if (error != GL_NO_ERROR) goto done;
        }
        if (!p_eglSwapBuffers(display, surface)) goto done;
    }
    passed = 1;
done:
    p_glBindFramebuffer(GL_FRAMEBUFFER, 0);
    p_glBindBufferBase(GL_UNIFORM_BUFFER, 0, 0);
    if (program) p_glDeleteProgram(program);
    if (fs) p_glDeleteShader(fs);
    if (ubo) p_glDeleteBuffers(1, &ubo);
    p_glDeleteFramebuffers(2, targets); p_glDeleteTextures(3, textures);
    note("ASYNC postprocess frames=160 result=%s", passed ? "PASS" : "FAIL");
    return passed;
}

int main(void)
{
    WCHAR path[32768];
    if (!GetModuleFileNameW(NULL, path, 32768)) return 2;
    WCHAR *tail = wcsrchr(path, L'\\'); if (!tail) return 2;
    wcscpy(tail + 1, L"angle-result.txt"); journal = _wfopen(path, L"w");
    if (!journal) return 2;
    int passed = 0;
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    HWND window = NULL;
    GLuint vs = 0, fs = 0, program = 0, texture = 0;
    const char *run = getenv("WINEVISION_PROBE_RUN_ID");
    note("START angle-drawing-v1 backend=d3d11 device=hardware run=%s", run ? run : "manual");
    if (!load_functions()) goto done;
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)p_eglGetProcAddress("eglGetPlatformDisplayEXT");
    const EGLint attributes[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
        EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE, EGL_NONE};
    if (!get_display) goto done;
    display = get_display(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, attributes);
    EGLint major, minor;
    if (display == EGL_NO_DISPLAY || !p_eglInitialize(display, &major, &minor)) goto done;
    note("EGL initialized=%d.%d", major, minor);
    if (!p_eglBindAPI(EGL_OPENGL_ES_API)) goto done;
    const char *color_bits = getenv("ANGLE_PROBE_COLOR_BITS");
    const int ten_bit = color_bits && !strcmp(color_bits, "10");
    note("CONFIG requested-rgb=%d alpha=%d", ten_bit ? 10 : 8, ten_bit ? 2 : 8);
    const EGLint config_attributes[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE,
        EGL_OPENGL_ES3_BIT_KHR, EGL_RED_SIZE, ten_bit ? 10 : 8, EGL_GREEN_SIZE, ten_bit ? 10 : 8,
        EGL_BLUE_SIZE, ten_bit ? 10 : 8, EGL_ALPHA_SIZE, ten_bit ? 2 : 8, EGL_NONE};
    EGLConfig config;
    EGLint count;
    if (!p_eglChooseConfig(display, config_attributes, &config, 1, &count) || count != 1) goto done;
    EGLint actual[4] = {0};
    const EGLint components[4] = {EGL_RED_SIZE, EGL_GREEN_SIZE, EGL_BLUE_SIZE, EGL_ALPHA_SIZE};
    for (unsigned c = 0; c < 4; ++c)
        if (!p_eglGetConfigAttrib(display, config, components[c], &actual[c])) goto done;
    note("CONFIG actual-rgba=%d,%d,%d,%d", actual[0], actual[1], actual[2], actual[3]);
    for (unsigned c = 0; c < 4; ++c)
        if (actual[c] != (c == 3 ? (ten_bit ? 2 : 8) : (ten_bit ? 10 : 8))) goto done;
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = DefWindowProcW; wc.hInstance = GetModuleHandleW(NULL); wc.lpszClassName = L"WineVisionAngleProbe";
    if (!RegisterClassW(&wc)) goto done;
    window = CreateWindowW(wc.lpszClassName, L"WineVision ANGLE pixel probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT, 384, 320, NULL, NULL, wc.hInstance, NULL);
    if (!window) goto done;
    const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context = p_eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    surface = p_eglCreateWindowSurface(display, config, window, NULL);
    if (context == EGL_NO_CONTEXT || surface == EGL_NO_SURFACE || !p_eglMakeCurrent(display, surface, surface, context)) goto done;
    note("GL renderer=%s version=%s", p_glGetString(GL_RENDERER), p_glGetString(GL_VERSION));
    vs = shader(GL_VERTEX_SHADER, "#version 300 es\nuniform bool point; void main(){"
        "vec2 p=gl_VertexID==0?vec2(-1,-1):gl_VertexID==1?vec2(3,-1):vec2(-1,3);"
        "gl_Position=point?vec4(0,0,0,1):vec4(p,0,1); gl_PointSize=16.0;}");
    fs = shader(GL_FRAGMENT_SHADER, "#version 300 es\nprecision highp float; uniform sampler2D image;"
        "uniform bool point; out vec4 color; void main(){color=texture(image,point?gl_PointCoord:vec2(.5));}");
    if (!vs || !fs) goto done;
    program = p_glCreateProgram(); p_glAttachShader(program, vs); p_glAttachShader(program, fs); p_glLinkProgram(program);
    GLint linked = 0; p_glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) { char log[768]; p_glGetProgramInfoLog(program, sizeof(log), NULL, log); note("FAIL stage=link message=%s", log); goto done; }
    const unsigned char texel[] = {0, 0, 255, 128};
    p_glGenTextures(1, &texture); p_glBindTexture(GL_TEXTURE_2D, texture);
    p_glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, texel);
    p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    GLint mode = p_glGetUniformLocation(program, "point");
    for (int frame = 0; frame < 12; ++frame) {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
        EGLint width, height;
        if (!p_eglQuerySurface(display, surface, EGL_WIDTH, &width) ||
            !p_eglQuerySurface(display, surface, EGL_HEIGHT, &height) || width < 32 || height < 32) goto done;
        if (!draw_and_check(program, mode, frame % 2, width, height) || !p_eglSwapBuffers(display, surface)) goto done;
        if (frame == 5) SetWindowPos(window, NULL, 0, 0, 512, 384, SWP_NOMOVE | SWP_NOZORDER);
    }
    // A valid BC7 mode-0 block with zero RGB endpoints is opaque black.
    // This reproduces the game's compressed-asset allocation path, which must
    // never inherit an uninitialized request for additional lossy compression.
    const unsigned char bc7[16] = {1};
    p_glCompressedTexImage2D(GL_TEXTURE_2D, 0, 0x8e8c /* GL_COMPRESSED_RGBA_BPTC_UNORM_EXT */,
                            4, 4, 0, sizeof(bc7), bc7);
    if (p_glGetError() != GL_NO_ERROR) { note("FAIL stage=bc7-upload"); goto done; }
    p_glUniform1i(mode, 0);
    p_glDrawArrays(GL_TRIANGLES, 0, 3);
    unsigned char compressed_pixel[4] = {255, 255, 255, 0};
    p_glReadPixels(128, 128, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, compressed_pixel);
    GLenum compressed_error = p_glGetError();
    note("PIXEL format=BC7 rgba=%u,%u,%u,%u error=0x%x", compressed_pixel[0], compressed_pixel[1],
         compressed_pixel[2], compressed_pixel[3], compressed_error);
    if (compressed_error != GL_NO_ERROR || compressed_pixel[0] > 2 || compressed_pixel[1] > 2 ||
        compressed_pixel[2] > 2 || compressed_pixel[3] < 253 || !p_eglSwapBuffers(display, surface)) goto done;
    if (!asynchronous_postprocess(display, surface, vs, program)) goto done;
    passed = 1;
done:
    if (!passed && p_eglGetError) note("FAIL egl=0x%x win32=%lu", p_eglGetError(), GetLastError());
    /* Keep teardown uninstrumented: symbol loading and an extra guest thread
     * changed its timing. Capture native stacks externally if this stalls. */
    note("CLEANUP begin gl-objects");
    if (program) p_glDeleteProgram(program);
    if (vs) p_glDeleteShader(vs);
    if (fs) p_glDeleteShader(fs);
    if (texture) p_glDeleteTextures(1, &texture);
    note("CLEANUP gl-objects released");
    if (display != EGL_NO_DISPLAY && p_eglMakeCurrent) {
        note("CLEANUP release-current begin");
        p_eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        note("CLEANUP release-current end");
        if (surface != EGL_NO_SURFACE) p_eglDestroySurface(display, surface);
        note("CLEANUP destroy-surface end");
        if (context != EGL_NO_CONTEXT) p_eglDestroyContext(display, context);
        note("CLEANUP destroy-context end");
        p_eglTerminate(display);
        note("CLEANUP terminate end");
    }
    if (window) DestroyWindow(window);
    if (gl_module) FreeLibrary(gl_module);
    if (egl_module) FreeLibrary(egl_module);
    note("CLEANUP unload-dlls end");
    note("RESULT %s", passed ? "PASS" : "FAIL");
    fclose(journal);
    return passed ? 0 : 1;
}
