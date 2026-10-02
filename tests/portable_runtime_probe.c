/* Owned window + HLSL draw/readback smoke test. No game/process attachment.
 * This checks functional runtime assembly, not gameplay performance or input.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <string.h>

#define CHECK(call) do { HRESULT hr=(call); if(FAILED(hr)) { \
    fprintf(stderr,"probe failure at line %d: 0x%08lx\n",__LINE__,(unsigned long)hr); return 1; } } while(0)

int main(void)
{
    HWND window=CreateWindowExW(0,L"STATIC",L"Portable runtime qualification",WS_OVERLAPPEDWINDOW,
                                0,0,64,64,NULL,NULL,NULL,NULL);
    if(!window) { fprintf(stderr,"Window driver failed: %lu\n",GetLastError()); return 1; }
    ID3D11Device *device=NULL;
    ID3D11DeviceContext *context=NULL;
    D3D_FEATURE_LEVEL level;
    CHECK(D3D11CreateDevice(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,NULL,0,D3D11_SDK_VERSION,
                           &device,&level,&context));
    const char *vs="float4 main(uint id:SV_VertexID):SV_Position { float2 p=float2((id<<1)&2,id&2); return float4(p*float2(2,-2)+float2(-1,1),0,1); }";
    const char *ps="float4 main():SV_Target { return float4(0.2,0.4,0.6,1); }";
    ID3DBlob *vb=NULL,*pb=NULL,*error=NULL;
    CHECK(D3DCompile(vs,strlen(vs),"portable-vs",NULL,NULL,"main","vs_5_0",0,0,&vb,&error));
    if(error) { ID3D10Blob_Release(error); error=NULL; }
    CHECK(D3DCompile(ps,strlen(ps),"portable-ps",NULL,NULL,"main","ps_5_0",0,0,&pb,&error));
    if(error) ID3D10Blob_Release(error);
    ID3D11VertexShader *vertex=NULL;
    ID3D11PixelShader *pixel=NULL;
    CHECK(ID3D11Device_CreateVertexShader(device,ID3D10Blob_GetBufferPointer(vb),ID3D10Blob_GetBufferSize(vb),NULL,&vertex));
    CHECK(ID3D11Device_CreatePixelShader(device,ID3D10Blob_GetBufferPointer(pb),ID3D10Blob_GetBufferSize(pb),NULL,&pixel));
    ID3D10Blob_Release(vb); ID3D10Blob_Release(pb);
    D3D11_TEXTURE2D_DESC desc={0};
    desc.Width=32; desc.Height=32; desc.MipLevels=1; desc.ArraySize=1;
    desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM; desc.SampleDesc.Count=1;
    desc.Usage=D3D11_USAGE_DEFAULT; desc.BindFlags=D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *texture=NULL,*staging=NULL;
    ID3D11RenderTargetView *target=NULL;
    CHECK(ID3D11Device_CreateTexture2D(device,&desc,NULL,&texture));
    CHECK(ID3D11Device_CreateRenderTargetView(device,(ID3D11Resource*)texture,NULL,&target));
    desc.Usage=D3D11_USAGE_STAGING; desc.BindFlags=0; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
    CHECK(ID3D11Device_CreateTexture2D(device,&desc,NULL,&staging));
    D3D11_RASTERIZER_DESC raster={0};
    raster.FillMode=D3D11_FILL_SOLID; raster.CullMode=D3D11_CULL_NONE; raster.DepthClipEnable=TRUE;
    ID3D11RasterizerState *rasterState=NULL;
    CHECK(ID3D11Device_CreateRasterizerState(device,&raster,&rasterState));
    D3D11_VIEWPORT viewport={0,0,32,32,0,1};
    ID3D11DeviceContext_RSSetState(context,rasterState);
    ID3D11DeviceContext_RSSetViewports(context,1,&viewport);
    ID3D11DeviceContext_OMSetRenderTargets(context,1,&target,NULL);
    ID3D11DeviceContext_IASetPrimitiveTopology(context,D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(context,vertex,NULL,0);
    ID3D11DeviceContext_PSSetShader(context,pixel,NULL,0);
    const float clear[4]={1,0,0,1};
    ID3D11DeviceContext_ClearRenderTargetView(context,target,clear);
    ID3D11DeviceContext_Draw(context,3,0);
    ID3D11DeviceContext_CopyResource(context,(ID3D11Resource*)staging,(ID3D11Resource*)texture);
    D3D11_MAPPED_SUBRESOURCE mapped={0};
    CHECK(ID3D11DeviceContext_Map(context,(ID3D11Resource*)staging,0,D3D11_MAP_READ,0,&mapped));
    unsigned char *rgba=(unsigned char*)mapped.pData+16*mapped.RowPitch+16*4;
    int passed=rgba[0]==51 && rgba[1]==102 && rgba[2]==153 && rgba[3]==255;
    printf("{\"window_created\":true,\"feature_level\":%u,\"shader_readback\":%s,\"rgba\":[%u,%u,%u,%u]}\n",
           level,passed?"true":"false",rgba[0],rgba[1],rgba[2],rgba[3]);
    ID3D11DeviceContext_Unmap(context,(ID3D11Resource*)staging,0);
    ID3D11DeviceContext_ClearState(context); ID3D11DeviceContext_Flush(context);
    ID3D11RasterizerState_Release(rasterState); ID3D11RenderTargetView_Release(target);
    ID3D11Texture2D_Release(texture); ID3D11Texture2D_Release(staging);
    ID3D11VertexShader_Release(vertex); ID3D11PixelShader_Release(pixel);
    ID3D11DeviceContext_Release(context); ID3D11Device_Release(device); DestroyWindow(window);
    return passed?0:1;
}
