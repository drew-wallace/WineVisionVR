#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <cstdio>
#include <cstdlib>

static FILE* logFile;
static void check(bool ok, const char* operation) {
  fprintf(logFile, "%s %s\n", ok ? "PASS" : "FAIL", operation);
  fflush(logFile);
  if (!ok) { fprintf(logFile, "RESULT FAIL\n"); fclose(logFile); ExitProcess(1); }
}

int main() {
  logFile = fopen("mapping-result.txt", "w");
  if (!logFile) return 2;
  fprintf(logFile, "START gdi-surface run=%s\n", getenv("WINEVISION_PROBE_RUN_ID") ?: "missing");
  fflush(logFile);
  ID3D11Device* device = nullptr;
  ID3D11DeviceContext* context = nullptr;
  check(SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
    D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context)), "create device");
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = desc.Height = 16; desc.MipLevels = desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM; desc.SampleDesc.Count = 1;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.MiscFlags = D3D11_RESOURCE_MISC_GDI_COMPATIBLE;
  ID3D11Texture2D* texture = nullptr;
  check(SUCCEEDED(device->CreateTexture2D(&desc, nullptr, &texture)), "create GDI texture");
  IDXGISurface1* surface = nullptr;
  check(SUCCEEDED(texture->QueryInterface(IID_PPV_ARGS(&surface))) && surface, "query surface1");
  IUnknown *a = nullptr, *b = nullptr;
  texture->QueryInterface(IID_PPV_ARGS(&a)); surface->QueryInterface(IID_PPV_ARGS(&b));
  check(a && a == b, "COM identity"); a->Release(); b->Release();
  DXGI_SURFACE_DESC actual{};
  check(SUCCEEDED(surface->GetDesc(&actual)) && actual.Width == 16 && actual.Height == 16 && actual.Format == desc.Format, "surface description");
  check(FAILED(surface->ReleaseDC(nullptr)), "release without acquisition rejected");
  check(FAILED(surface->GetDC(TRUE, nullptr)), "null DC output rejected");
  HDC dc = nullptr, duplicate = reinterpret_cast<HDC>(1);
  check(SUCCEEDED(surface->GetDC(TRUE, &dc)) && dc, "acquire discard DC");
  check(FAILED(surface->GetDC(TRUE, &duplicate)) && !duplicate, "duplicate acquisition rejected");
  DXGI_MAPPED_RECT mapped{};
  check(FAILED(surface->Map(&mapped, DXGI_MAP_READ)), "map while DC acquired rejected");
  RECT full{0,0,16,16};
  HBRUSH brush = CreateSolidBrush(RGB(17,34,51));
  check(FillRect(dc, &full, brush) != 0, "GDI fill"); DeleteObject(brush);
  check(SUCCEEDED(surface->ReleaseDC(nullptr)), "upload GDI pixels");
  D3D11_TEXTURE2D_DESC readDesc = desc;
  readDesc.Usage = D3D11_USAGE_STAGING; readDesc.BindFlags = readDesc.MiscFlags = 0;
  readDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ID3D11Texture2D* staging = nullptr;
  check(SUCCEEDED(device->CreateTexture2D(&readDesc, nullptr, &staging)), "create readback texture");
  auto verify = [&](bool modified) {
    context->CopyResource(staging, texture);
    D3D11_MAPPED_SUBRESOURCE pixels{};
    check(SUCCEEDED(context->Map(staging, 0, D3D11_MAP_READ, 0, &pixels)), "read back GPU texture");
    bool correct = pixels.pData && pixels.RowPitch >= 64;
    for (unsigned y=0; correct && y<16; ++y) for (unsigned x=0; x<16; ++x) {
      const auto* p = static_cast<const unsigned char*>(pixels.pData) + y*pixels.RowPitch + x*4;
      const bool changed = modified && x < 4 && y < 4;
      if (p[0] != (changed?77:51) || p[1] != (changed?88:34) || p[2] != (changed?99:17)) correct = false;
    }
    context->Unmap(staging, 0);
    check(correct, modified ? "modified and preserved GPU pixels" : "GDI pixels reached GPU");
  };
  verify(false);
  check(SUCCEEDED(surface->GetDC(FALSE, &dc)), "acquire preserving DC");
  check(GetPixel(dc,8,8) == RGB(17,34,51), "GPU contents preserved in DC");
  RECT corner{0,0,4,4}; brush = CreateSolidBrush(RGB(99,88,77));
  check(FillRect(dc,&corner,brush) != 0, "modify corner"); DeleteObject(brush);
  check(SUCCEEDED(surface->ReleaseDC(&corner)), "release dirty region"); verify(true);
  check(SUCCEEDED(surface->GetDC(TRUE,&dc)), "acquire for empty update");
  RECT empty{}; check(SUCCEEDED(surface->ReleaseDC(&empty)), "empty update"); verify(true);
  desc.MiscFlags = 0;
  ID3D11Texture2D* ordinary = nullptr;
  check(SUCCEEDED(device->CreateTexture2D(&desc,nullptr,&ordinary)), "create ordinary texture");
  IDXGISurface1* ordinarySurface = nullptr;
  check(SUCCEEDED(ordinary->QueryInterface(IID_PPV_ARGS(&ordinarySurface))), "ordinary surface query");
  check(FAILED(ordinarySurface->GetDC(TRUE,&dc)) && !dc, "non-GDI DC rejected");
  ordinarySurface->Release(); ordinary->Release();
  staging->Release(); surface->Release(); texture->Release(); context->Release(); device->Release();
  fprintf(logFile,"RESULT PASS\n"); fclose(logFile); return 0;
}
