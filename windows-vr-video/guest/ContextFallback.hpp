// Unsupported AMF context APIs return explicit errors; real DX11 and host buffers are implemented by Context.
struct ContextFallback : Properties<AMFContext> {
  AMF_RESULT AMF_STD_CALL Terminate() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL InitDX9(void* pDX9Device) override { return AMF_NOT_SUPPORTED; }
  void* AMF_STD_CALL GetDX9Device(AMF_DX_VERSION dxVersionRequired) override { return nullptr; }
  AMF_RESULT AMF_STD_CALL LockDX9() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL UnlockDX9() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL InitDX11(void* pDX11Device, AMF_DX_VERSION dxVersionRequired) override { return AMF_NOT_SUPPORTED; }
  void* AMF_STD_CALL GetDX11Device(AMF_DX_VERSION dxVersionRequired) override { return nullptr; }
  AMF_RESULT AMF_STD_CALL LockDX11() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL UnlockDX11() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL InitOpenCL(void* pCommandQueue) override { return AMF_NOT_SUPPORTED; }
  void* AMF_STD_CALL GetOpenCLContext() override { return nullptr; }
  void* AMF_STD_CALL GetOpenCLCommandQueue() override { return nullptr; }
  void* AMF_STD_CALL GetOpenCLDeviceID() override { return nullptr; }
  AMF_RESULT AMF_STD_CALL GetOpenCLComputeFactory(AMFComputeFactory **ppFactory) override { if(ppFactory)*ppFactory=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL InitOpenCLEx(AMFComputeDevice *pDevice) override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL LockOpenCL() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL UnlockOpenCL() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL InitOpenGL(amf_handle hOpenGLContext, amf_handle hWindow, amf_handle hDC) override { return AMF_NOT_SUPPORTED; }
  amf_handle AMF_STD_CALL GetOpenGLContext() override { return nullptr; }
  amf_handle AMF_STD_CALL GetOpenGLDrawable() override { return nullptr; }
  AMF_RESULT AMF_STD_CALL LockOpenGL() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL UnlockOpenGL() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL InitXV(void* pXVDevice) override { return AMF_NOT_SUPPORTED; }
  void* AMF_STD_CALL GetXVDevice() override { return nullptr; }
  AMF_RESULT AMF_STD_CALL LockXV() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL UnlockXV() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL InitGralloc(void* pGrallocDevice) override { return AMF_NOT_SUPPORTED; }
  void* AMF_STD_CALL GetGrallocDevice() override { return nullptr; }
  AMF_RESULT AMF_STD_CALL LockGralloc() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL UnlockGralloc() override { return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL AllocBuffer(AMF_MEMORY_TYPE type, amf_size size, AMFBuffer** ppBuffer) override { if(ppBuffer)*ppBuffer=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL AllocSurface(AMF_MEMORY_TYPE type, AMF_SURFACE_FORMAT format, amf_int32 width, amf_int32 height, AMFSurface** ppSurface) override { if(ppSurface)*ppSurface=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL AllocAudioBuffer(AMF_MEMORY_TYPE type, AMF_AUDIO_FORMAT format, amf_int32 samples, amf_int32 sampleRate, amf_int32 channels, AMFAudioBuffer** ppAudioBuffer) override { if(ppAudioBuffer)*ppAudioBuffer=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL CreateBufferFromHostNative(void* pHostBuffer, amf_size size, AMFBuffer** ppBuffer, AMFBufferObserver* pObserver) override { if(ppBuffer)*ppBuffer=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL CreateSurfaceFromHostNative(AMF_SURFACE_FORMAT format, amf_int32 width, amf_int32 height, amf_int32 hPitch, amf_int32 vPitch, void* pData, AMFSurface** ppSurface, AMFSurfaceObserver* pObserver) override { if(ppSurface)*ppSurface=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL CreateSurfaceFromDX9Native(void* pDX9Surface, AMFSurface** ppSurface, AMFSurfaceObserver* pObserver) override { if(ppSurface)*ppSurface=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL CreateSurfaceFromDX11Native(void* pDX11Surface, AMFSurface** ppSurface, AMFSurfaceObserver* pObserver) override { if(ppSurface)*ppSurface=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL CreateSurfaceFromOpenGLNative(AMF_SURFACE_FORMAT format, amf_handle hGLTextureID, AMFSurface** ppSurface, AMFSurfaceObserver* pObserver) override { if(ppSurface)*ppSurface=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL CreateSurfaceFromGrallocNative(amf_handle hGrallocSurface, AMFSurface** ppSurface, AMFSurfaceObserver* pObserver) override { if(ppSurface)*ppSurface=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL CreateSurfaceFromOpenCLNative(AMF_SURFACE_FORMAT format, amf_int32 width, amf_int32 height, void** pClPlanes, AMFSurface** ppSurface, AMFSurfaceObserver* pObserver) override { if(ppSurface)*ppSurface=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL CreateBufferFromOpenCLNative(void* pCLBuffer, amf_size size, AMFBuffer** ppBuffer) override { if(ppBuffer)*ppBuffer=nullptr;return AMF_NOT_SUPPORTED; }
  AMF_RESULT AMF_STD_CALL GetCompute(AMF_MEMORY_TYPE eMemType, AMFCompute** ppCompute) override { if(ppCompute)*ppCompute=nullptr;return AMF_NOT_SUPPORTED; }
};
