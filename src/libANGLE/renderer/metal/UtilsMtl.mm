//
// Copyright 2019 The ANGLE Project Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// UtilsMtl.mm:
//    Implements the class methods for UtilsMtl.
//

#include "libANGLE/renderer/metal/UtilsMtl.h"

#include <utility>

#include "common/debug.h"
#include "libANGLE/renderer/metal/ContextMtl.h"
#include "libANGLE/renderer/metal/RendererMtl.h"
#include "libANGLE/renderer/metal/mtl_common.h"
#include "libANGLE/renderer/metal/mtl_utils.h"
#include "libANGLE/renderer/metal/shaders/compiled/mtl_default_shaders.inc"
#include "libANGLE/renderer/metal/shaders/mtl_default_shaders_src_autogen.inc"

namespace rx
{
namespace
{

#define SOURCE_BUFFER_ALIGNED_CONSTANT_NAME @"kSourceBufferAligned"
#define SOURCE_IDX_IS_U8_CONSTANT_NAME @"kSourceIndexIsU8"
#define SOURCE_IDX_IS_U16_CONSTANT_NAME @"kSourceIndexIsU16"
#define SOURCE_IDX_IS_U32_CONSTANT_NAME @"kSourceIndexIsU32"

struct ClearParamsUniform
{
    float clearColor[4];
    float clearDepth;
    float padding[3];
};

struct BlitParamsUniform
{
    // 0: lower left, 1: lower right, 2: upper left, 3: upper right
    float srcTexCoords[4][2];
    int srcLevel         = 0;
    uint8_t srcLuminance = 0;  // source texture is luminance texture
    uint8_t dstFlipY     = 0;
    uint8_t dstLuminance = 0;  // dest texture is luminace
    uint8_t padding1;
    float padding2[2];
};

struct IndexConversionUniform
{
    uint32_t srcOffset;
    uint32_t indexCount;
    uint32_t padding[2];
};

template <typename T>
angle::Result GenTriFanFromClientElements(const gl::Context *context,
                                          GLsizei count,
                                          const T *indices,
                                          mtl::BufferRef dstBuffer,
                                          uint32_t dstOffset)
{
    ASSERT(count > 2);
    ContextMtl *contextMtl = mtl::GetImpl(context);
    uint32_t *dstPtr       = reinterpret_cast<uint32_t *>(dstBuffer->map(contextMtl) + dstOffset);
    T firstIdx;
    memcpy(&firstIdx, indices, sizeof(firstIdx));
    for (GLsizei i = 2; i < count; ++i)
    {
        T srcPrevIdx, srcIdx;
        memcpy(&srcPrevIdx, indices + i - 1, sizeof(srcPrevIdx));
        memcpy(&srcIdx, indices + i, sizeof(srcIdx));

        uint32_t triIndices[3];
        triIndices[0] = firstIdx;
        triIndices[1] = srcPrevIdx;
        triIndices[2] = srcIdx;

        memcpy(dstPtr + 3 * (i - 2), triIndices, sizeof(triIndices));
    }
    dstBuffer->unmap(contextMtl);

    return angle::Result::Continue;
}

}  // namespace

bool UtilsMtl::IndexConvesionPipelineCacheKey::operator==(
    const IndexConvesionPipelineCacheKey &other) const
{
    return srcType == other.srcType && srcBufferOffsetAligned == other.srcBufferOffsetAligned;
}
bool UtilsMtl::IndexConvesionPipelineCacheKey::operator<(
    const IndexConvesionPipelineCacheKey &other) const
{
    if (!srcBufferOffsetAligned && other.srcBufferOffsetAligned)
    {
        return true;
    }
    if (srcBufferOffsetAligned && !other.srcBufferOffsetAligned)
    {
        return false;
    }
    return static_cast<int>(srcType) < static_cast<int>(other.srcType);
}

UtilsMtl::UtilsMtl(RendererMtl *renderer) : mtl::Context(renderer) {}

UtilsMtl::~UtilsMtl() {}

angle::Result UtilsMtl::initialize()
{
    auto re = initShaderLibrary();
    if (re != angle::Result::Continue)
    {
        return re;
    }

    initClearResources();
    initBlitResources();

    return angle::Result::Continue;
}

void UtilsMtl::onDestroy()
{
    mDefaultShaders = nil;

    mClearRenderPipelineCache.clear();
    mBlitRenderPipelineCache.clear();
    mBlitPremultiplyAlphaRenderPipelineCache.clear();
    mBlitUnmultiplyAlphaRenderPipelineCache.clear();

    mIndexConversionPipelineCaches.clear();
    mTriFanFromElemArrayGeneratorPipelineCaches.clear();

    mTriFanFromArraysGeneratorPipeline = nil;
}

// override mtl::ErrorHandler
void UtilsMtl::handleError(GLenum glErrorCode,
                           const char *file,
                           const char *function,
                           unsigned int line)
{
    ERR() << "Metal backend encountered an internal error. Code=" << glErrorCode << ".";
}

void UtilsMtl::handleError(NSError *nserror,
                           const char *file,
                           const char *function,
                           unsigned int line)
{
    if (!nserror)
    {
        return;
    }

    std::stringstream errorStream;
    ERR() << "Metal backend encountered an internal error: \n"
          << nserror.localizedDescription.UTF8String;
}

angle::Result UtilsMtl::initShaderLibrary()
{
    mtl::AutoObjCObj<NSError> err = nil;

#if !defined(NDEBUG)
    mDefaultShaders = mtl::CreateShaderLibrary(
        getRenderer()->getMetalDevice(), default_metallib_src, sizeof(default_metallib_src), &err);
#else
    mDefaultShaders = mtl::CreateShaderLibraryFromBinary(getRenderer()->getMetalDevice(),
                                                         compiled_default_metallib,
                                                         compiled_default_metallib_len, &err);
#endif

    if (err && !mDefaultShaders)
    {
        ANGLE_MTL_CHECK(this, false, err.get());
        return angle::Result::Stop;
    }

    return angle::Result::Continue;
}

void UtilsMtl::initClearResources()
{
    ANGLE_MTL_OBJC_SCOPE
    {
        // Shader pipeline
        mClearRenderPipelineCache.setVertexShader(
            this, [mDefaultShaders.get() newFunctionWithName:@"clearVS"]);
        mClearRenderPipelineCache.setFragmentShader(
            this, [mDefaultShaders.get() newFunctionWithName:@"clearFS"]);
    }
}

void UtilsMtl::initBlitResources()
{
    ANGLE_MTL_OBJC_SCOPE
    {
        auto shaderLib    = mDefaultShaders.get();
        auto vertexShader = [shaderLib newFunctionWithName:@"blitVS"];

        mBlitRenderPipelineCache.setVertexShader(this, vertexShader);
        mBlitRenderPipelineCache.setFragmentShader(this, [shaderLib newFunctionWithName:@"blitFS"]);

        mBlitPremultiplyAlphaRenderPipelineCache.setVertexShader(this, vertexShader);
        mBlitPremultiplyAlphaRenderPipelineCache.setFragmentShader(
            this, [shaderLib newFunctionWithName:@"blitPremultiplyAlphaFS"]);

        mBlitUnmultiplyAlphaRenderPipelineCache.setVertexShader(this, vertexShader);
        mBlitUnmultiplyAlphaRenderPipelineCache.setFragmentShader(
            this, [shaderLib newFunctionWithName:@"blitUnmultiplyAlphaFS"]);
    }
}

void UtilsMtl::clearWithDraw(const gl::Context *context,
                             mtl::RenderCommandEncoder *cmdEncoder,
                             const ClearParams &params)
{
    auto overridedParams = params;
    // Make sure we don't clear attachment that doesn't exist
    const mtl::RenderPassDesc &renderPassDesc = cmdEncoder->renderPassDesc();
    if (renderPassDesc.numColorAttachments == 0)
    {
        overridedParams.clearColor.reset();
    }
    if (!renderPassDesc.depthAttachment.texture)
    {
        overridedParams.clearDepth.reset();
    }
    if (!renderPassDesc.stencilAttachment.texture)
    {
        overridedParams.clearStencil.reset();
    }

    if (!overridedParams.clearColor.valid() && !overridedParams.clearDepth.valid() &&
        !overridedParams.clearStencil.valid())
    {
        return;
    }

    setupClearWithDraw(context, cmdEncoder, overridedParams);

    // Draw the screen aligned quad
    cmdEncoder->draw(MTLPrimitiveTypeTriangle, 0, 6);

    // Invalidate current context's state
    auto contextMtl = mtl::GetImpl(context);
    contextMtl->invalidateState(context);
}

void UtilsMtl::blitWithDraw(const gl::Context *context,
                            mtl::RenderCommandEncoder *cmdEncoder,
                            const BlitParams &params)
{
    if (!params.src)
    {
        return;
    }
    setupBlitWithDraw(context, cmdEncoder, params);

    // Draw the screen aligned quad
    cmdEncoder->draw(MTLPrimitiveTypeTriangle, 0, 6);

    // Invalidate current context's state
    ContextMtl *contextMtl = mtl::GetImpl(context);
    contextMtl->invalidateState(context);
}

void UtilsMtl::setupClearWithDraw(const gl::Context *context,
                                  mtl::RenderCommandEncoder *cmdEncoder,
                                  const ClearParams &params)
{
    // Generate render pipeline state
    auto renderPipelineState = getClearRenderPipelineState(context, cmdEncoder, params);
    ASSERT(renderPipelineState);
    // Setup states
    setupDrawCommonStates(cmdEncoder);
    cmdEncoder->setRenderPipelineState(renderPipelineState);

    id<MTLDepthStencilState> dsState = getClearDepthStencilState(context, params);
    cmdEncoder->setDepthStencilState(dsState).setStencilRefVal(params.clearStencil.value());

    // Viewports
    const mtl::RenderPassDesc &renderPassDesc = cmdEncoder->renderPassDesc();

    MTLViewport viewport;
    MTLScissorRect scissorRect;

    mtl::RenderPassAttachmentDesc renderPassAttachment;

    if (renderPassDesc.numColorAttachments)
    {
        renderPassAttachment = renderPassDesc.colorAttachments[0];
    }
    else if (renderPassDesc.depthAttachment.texture)
    {
        renderPassAttachment = renderPassDesc.depthAttachment;
    }
    else
    {
        ASSERT(renderPassDesc.stencilAttachment.texture);
        renderPassAttachment = renderPassDesc.stencilAttachment;
    }

    auto texture = renderPassAttachment.texture;

    viewport = mtl::GetViewport(params.clearArea, texture->height(renderPassAttachment.level),
                                params.flipY);

    scissorRect = mtl::GetScissorRect(params.clearArea, texture->height(renderPassAttachment.level),
                                      params.flipY);

    cmdEncoder->setViewport(viewport);
    cmdEncoder->setScissorRect(scissorRect);

    // uniform
    ClearParamsUniform uniformParams;
    uniformParams.clearColor[0] = static_cast<float>(params.clearColor.value().red);
    uniformParams.clearColor[1] = static_cast<float>(params.clearColor.value().green);
    uniformParams.clearColor[2] = static_cast<float>(params.clearColor.value().blue);
    uniformParams.clearColor[3] = static_cast<float>(params.clearColor.value().alpha);
    uniformParams.clearDepth    = params.clearDepth.value();

    cmdEncoder->setVertexData(uniformParams, 0);
    cmdEncoder->setFragmentData(uniformParams, 0);
}

void UtilsMtl::setupBlitWithDraw(const gl::Context *context,
                                 mtl::RenderCommandEncoder *cmdEncoder,
                                 const BlitParams &params)
{
    ASSERT(cmdEncoder->renderPassDesc().numColorAttachments == 1 && params.src);

    // Generate render pipeline state
    auto renderPipelineState = getBlitRenderPipelineState(context, cmdEncoder, params);
    ASSERT(renderPipelineState);
    // Setup states
    setupDrawCommonStates(cmdEncoder);
    cmdEncoder->setRenderPipelineState(renderPipelineState);
    cmdEncoder->setDepthStencilState(getRenderer()->getStateCache().getNullDepthStencilState(this));

    // Viewport
    const mtl::RenderPassDesc &renderPassDesc = cmdEncoder->renderPassDesc();
    const mtl::RenderPassColorAttachmentDesc &renderPassColorAttachment =
        renderPassDesc.colorAttachments[0];
    auto texture = renderPassColorAttachment.texture;

    gl::Rectangle dstRect(params.dstOffset.x, params.dstOffset.y, params.srcRect.width,
                          params.srcRect.height);
    MTLViewport viewportMtl = mtl::GetViewport(
        dstRect, texture->height(renderPassColorAttachment.level), params.dstFlipY);
    MTLScissorRect scissorRectMtl = mtl::GetScissorRect(
        dstRect, texture->height(renderPassColorAttachment.level), params.dstFlipY);
    cmdEncoder->setViewport(viewportMtl);
    cmdEncoder->setScissorRect(scissorRectMtl);

    cmdEncoder->setFragmentTexture(params.src, 0);

    // Uniform
    setupBlitWithDrawUniformData(cmdEncoder, params);
}

void UtilsMtl::setupDrawCommonStates(mtl::RenderCommandEncoder *cmdEncoder)
{
    cmdEncoder->setCullMode(MTLCullModeNone);
    cmdEncoder->setTriangleFillMode(MTLTriangleFillModeFill);
    cmdEncoder->setDepthBias(0, 0, 0);
}

id<MTLDepthStencilState> UtilsMtl::getClearDepthStencilState(const gl::Context *context,
                                                             const ClearParams &params)
{
    if (!params.clearDepth.valid() && !params.clearStencil.valid())
    {
        // Doesn't clear depth nor stencil
        return getRenderer()->getStateCache().getNullDepthStencilState(this);
    }

    ContextMtl *contextMtl = mtl::GetImpl(context);

    mtl::DepthStencilDesc desc;
    desc.reset();

    if (params.clearDepth.valid())
    {
        // Clear depth state
        desc.depthWriteEnabled = true;
    }
    else
    {
        desc.depthWriteEnabled = false;
    }

    if (params.clearStencil.valid())
    {
        // Clear stencil state
        desc.frontFaceStencil.depthStencilPassOperation = MTLStencilOperationReplace;
        desc.frontFaceStencil.writeMask                 = contextMtl->getStencilMask();
        desc.backFaceStencil.depthStencilPassOperation  = MTLStencilOperationReplace;
        desc.backFaceStencil.writeMask                  = contextMtl->getStencilMask();
    }

    return getRenderer()->getStateCache().getDepthStencilState(getRenderer()->getMetalDevice(),
                                                               desc);
}

id<MTLRenderPipelineState> UtilsMtl::getClearRenderPipelineState(
    const gl::Context *context,
    mtl::RenderCommandEncoder *cmdEncoder,
    const ClearParams &params)
{
    ContextMtl *contextMtl      = mtl::GetImpl(context);
    MTLColorWriteMask colorMask = contextMtl->getColorMask();
    if (!params.clearColor.valid())
    {
        colorMask = MTLColorWriteMaskNone;
    }

    mtl::RenderPipelineDesc pipelineDesc;
    const mtl::RenderPassDesc &renderPassDesc = cmdEncoder->renderPassDesc();

    renderPassDesc.populateRenderPipelineOutputDesc(colorMask, &pipelineDesc.outputDescriptor);

    pipelineDesc.inputPrimitiveTopology = mtl::kPrimitiveTopologyClassTriangle;

    return mClearRenderPipelineCache.getRenderPipelineState(contextMtl, pipelineDesc);
}

id<MTLRenderPipelineState> UtilsMtl::getBlitRenderPipelineState(
    const gl::Context *context,
    mtl::RenderCommandEncoder *cmdEncoder,
    const BlitParams &params)
{
    ContextMtl *contextMtl = mtl::GetImpl(context);
    mtl::RenderPipelineDesc pipelineDesc;
    const mtl::RenderPassDesc &renderPassDesc = cmdEncoder->renderPassDesc();

    renderPassDesc.populateRenderPipelineOutputDesc(params.dstColorMask,
                                                    &pipelineDesc.outputDescriptor);

    pipelineDesc.inputPrimitiveTopology = mtl::kPrimitiveTopologyClassTriangle;

    RenderPipelineCacheMtl *pipelineCache;
    if (params.unpackPremultiplyAlpha == params.unpackUnmultiplyAlpha)
    {
        pipelineCache = &mBlitRenderPipelineCache;
    }
    else if (params.unpackPremultiplyAlpha)
    {
        pipelineCache = &mBlitPremultiplyAlphaRenderPipelineCache;
    }
    else
    {
        pipelineCache = &mBlitUnmultiplyAlphaRenderPipelineCache;
    }

    return pipelineCache->getRenderPipelineState(contextMtl, pipelineDesc);
}

void UtilsMtl::setupBlitWithDrawUniformData(mtl::RenderCommandEncoder *cmdEncoder,
                                            const BlitParams &params)
{
    BlitParamsUniform uniformParams;
    uniformParams.dstFlipY     = params.dstFlipY ? 1 : 0;
    uniformParams.srcLevel     = params.srcLevel;
    uniformParams.dstLuminance = params.dstLuminance ? 1 : 0;

    // Compute source texCoords
    auto srcWidth  = params.src->width(params.srcLevel);
    auto srcHeight = params.src->height(params.srcLevel);

    int x0 = params.srcRect.x0();  // left
    int x1 = params.srcRect.x1();  // right
    int y0 = params.srcRect.y0();  // lower
    int y1 = params.srcRect.y1();  // upper
    if (params.srcYFlipped)
    {
        // If source's Y has been flipped, such as default framebuffer, then adjust the real source
        // rectangle.
        y0 = srcHeight - y1;
        y1 = y0 + params.srcRect.height;
        std::swap(y0, y1);
    }

    if (params.unpackFlipY)
    {
        std::swap(y0, y1);
    }

    float u0 = (float)x0 / srcWidth;
    float u1 = (float)x1 / srcWidth;
    float v0 = (float)y0 / srcHeight;
    float v1 = (float)y1 / srcHeight;

    // lower left
    uniformParams.srcTexCoords[0][0] = u0;
    uniformParams.srcTexCoords[0][1] = v0;

    // lower right
    uniformParams.srcTexCoords[1][0] = u1;
    uniformParams.srcTexCoords[1][1] = v0;

    // upper left
    uniformParams.srcTexCoords[2][0] = u0;
    uniformParams.srcTexCoords[2][1] = v1;

    // upper right
    uniformParams.srcTexCoords[3][0] = u1;
    uniformParams.srcTexCoords[3][1] = v1;

    cmdEncoder->setVertexData(uniformParams, 0);
    cmdEncoder->setFragmentData(uniformParams, 0);
}

mtl::AutoObjCPtr<id<MTLComputePipelineState>> UtilsMtl::getIndexConversionPipeline(
    ContextMtl *context,
    gl::DrawElementsType srcType,
    uint32_t srcOffset)
{
    id<MTLDevice> metalDevice = context->getMetalDevice();
    size_t elementSize        = gl::GetDrawElementsTypeSize(srcType);
    bool aligned              = (srcOffset % elementSize) == 0;

    IndexConvesionPipelineCacheKey key = {srcType, aligned};

    auto &cache = mIndexConversionPipelineCaches[key];

    if (!cache)
    {
        ANGLE_MTL_OBJC_SCOPE
        {
            auto shaderLib         = mDefaultShaders.get();
            id<MTLFunction> shader = nil;
            auto funcConstants = [[[MTLFunctionConstantValues alloc] init] ANGLE_MTL_AUTORELEASE];
            NSError *err       = nil;

            [funcConstants setConstantValue:&aligned
                                       type:MTLDataTypeBool
                                   withName:SOURCE_BUFFER_ALIGNED_CONSTANT_NAME];

            switch (srcType)
            {
                case gl::DrawElementsType::UnsignedByte:
                    shader = [shaderLib newFunctionWithName:@"convertIndexU8ToU16"];
                    break;
                case gl::DrawElementsType::UnsignedShort:
                    shader = [shaderLib newFunctionWithName:@"convertIndexU16"
                                             constantValues:funcConstants
                                                      error:&err];
                    break;
                case gl::DrawElementsType::UnsignedInt:
                    shader = [shaderLib newFunctionWithName:@"convertIndexU32"
                                             constantValues:funcConstants
                                                      error:&err];
                    break;
                default:
                    UNREACHABLE();
            }

            if (err && !shader)
            {
                ERR() << "Internal error: " << err.localizedDescription.UTF8String << "\n";
            }
            ASSERT(shader);

            cache = [metalDevice newComputePipelineStateWithFunction:shader error:&err];
            if (err && !cache)
            {
                ERR() << "Internal error: " << err.localizedDescription.UTF8String << "\n";
            }
            ASSERT(cache);
        }
    }

    return cache;
}

mtl::AutoObjCPtr<id<MTLComputePipelineState>> UtilsMtl::getTriFanFromElemArrayGeneratorPipeline(
    ContextMtl *context,
    gl::DrawElementsType srcType,
    uint32_t srcOffset)
{
    id<MTLDevice> metalDevice = context->getMetalDevice();
    size_t elementSize        = gl::GetDrawElementsTypeSize(srcType);
    bool aligned              = (srcOffset % elementSize) == 0;

    IndexConvesionPipelineCacheKey key = {srcType, aligned};

    auto &cache = mIndexConversionPipelineCaches[key];

    if (!cache)
    {
        ANGLE_MTL_OBJC_SCOPE
        {
            auto shaderLib         = mDefaultShaders.get();
            id<MTLFunction> shader = nil;
            auto funcConstants = [[[MTLFunctionConstantValues alloc] init] ANGLE_MTL_AUTORELEASE];
            NSError *err       = nil;

            bool isU8  = false;
            bool isU16 = false;
            bool isU32 = false;

            switch (srcType)
            {
                case gl::DrawElementsType::UnsignedByte:
                    isU8 = true;
                    break;
                case gl::DrawElementsType::UnsignedShort:
                    isU16 = true;
                    break;
                case gl::DrawElementsType::UnsignedInt:
                    isU32 = true;
                    break;
                default:
                    UNREACHABLE();
            }

            [funcConstants setConstantValue:&aligned
                                       type:MTLDataTypeBool
                                   withName:SOURCE_BUFFER_ALIGNED_CONSTANT_NAME];
            [funcConstants setConstantValue:&isU8
                                       type:MTLDataTypeBool
                                   withName:SOURCE_IDX_IS_U8_CONSTANT_NAME];
            [funcConstants setConstantValue:&isU16
                                       type:MTLDataTypeBool
                                   withName:SOURCE_IDX_IS_U16_CONSTANT_NAME];
            [funcConstants setConstantValue:&isU32
                                       type:MTLDataTypeBool
                                   withName:SOURCE_IDX_IS_U32_CONSTANT_NAME];

            shader = [shaderLib newFunctionWithName:@"genTriFanIndicesFromElements"
                                     constantValues:funcConstants
                                              error:&err];
            if (err && !shader)
            {
                ERR() << "Internal error: " << err.localizedDescription.UTF8String << "\n";
            }
            ASSERT(shader);

            cache = [metalDevice newComputePipelineStateWithFunction:shader error:&err];
            if (err && !cache)
            {
                ERR() << "Internal error: " << err.localizedDescription.UTF8String << "\n";
            }
            ASSERT(cache);
        }
    }

    return cache;
}

angle::Result UtilsMtl::ensureTriFanFromArrayGeneratorInitialized(ContextMtl *context)
{
    if (!mTriFanFromArraysGeneratorPipeline)
    {
        ANGLE_MTL_OBJC_SCOPE
        {
            id<MTLDevice> metalDevice = context->getMetalDevice();
            auto shaderLib            = mDefaultShaders.get();
            NSError *err              = nil;
            id<MTLFunction> shader = [shaderLib newFunctionWithName:@"genTriFanIndicesFromArray"];

            mTriFanFromArraysGeneratorPipeline =
                [metalDevice newComputePipelineStateWithFunction:shader error:&err];
            if (err && !mTriFanFromArraysGeneratorPipeline)
            {
                ERR() << "Internal error: " << err.localizedDescription.UTF8String << "\n";
            }

            ASSERT(mTriFanFromArraysGeneratorPipeline);
        }
    }
    return angle::Result::Continue;
}

angle::Result UtilsMtl::convertIndexBuffer(const gl::Context *context,
                                           gl::DrawElementsType srcType,
                                           uint32_t indexCount,
                                           mtl::BufferRef srcBuffer,
                                           uint32_t srcOffset,
                                           mtl::BufferRef dstBuffer,
                                           uint32_t dstOffset)
{
    ContextMtl *contextMtl                 = mtl::GetImpl(context);
    mtl::ComputeCommandEncoder *cmdEncoder = contextMtl->getComputeCommandEncoder();
    ASSERT(cmdEncoder);

    mtl::AutoObjCPtr<id<MTLComputePipelineState>> pipelineState =
        getIndexConversionPipeline(contextMtl, srcType, srcOffset);

    ASSERT(pipelineState);

    cmdEncoder->setComputePipelineState(pipelineState);

    ASSERT((dstOffset % kBufferSettingOffsetAlignment) == 0);

    IndexConversionUniform uniform;
    uniform.srcOffset  = srcOffset;
    uniform.indexCount = indexCount;

    cmdEncoder->setData(uniform, 0);
    cmdEncoder->setBuffer(srcBuffer, 0, 1);
    cmdEncoder->setBuffer(dstBuffer, dstOffset, 2);

    ANGLE_TRY(dispatchCompute(context, cmdEncoder, pipelineState, indexCount));

    return angle::Result::Continue;
}

angle::Result UtilsMtl::generateTriFanBufferFromArrays(const gl::Context *context,
                                                       const TriFanFromArrayParams &params)
{
    ContextMtl *contextMtl                 = mtl::GetImpl(context);
    mtl::ComputeCommandEncoder *cmdEncoder = contextMtl->getComputeCommandEncoder();
    ASSERT(cmdEncoder);
    ANGLE_TRY(ensureTriFanFromArrayGeneratorInitialized(contextMtl));

    ASSERT(params.vertexCount > 2);

    cmdEncoder->setComputePipelineState(mTriFanFromArraysGeneratorPipeline);

    ASSERT((params.dstOffset % kBufferSettingOffsetAlignment) == 0);

    struct TriFanArrayParams
    {
        uint firstVertex;
        uint vertexCountFrom3rd;
        uint padding[2];
    } uniform;

    uniform.firstVertex        = params.firstVertex;
    uniform.vertexCountFrom3rd = params.vertexCount - 2;

    cmdEncoder->setData(uniform, 0);
    cmdEncoder->setBuffer(params.dstBuffer, params.dstOffset, 2);

    ANGLE_TRY(dispatchCompute(context, cmdEncoder, mTriFanFromArraysGeneratorPipeline,
                              uniform.vertexCountFrom3rd));

    return angle::Result::Continue;
}

angle::Result UtilsMtl::generateTriFanBufferFromElementsArray(
    const gl::Context *context,
    const TriFanFromElementArrayParams &params)
{
    ContextMtl *contextMtl                 = mtl::GetImpl(context);
    mtl::ComputeCommandEncoder *cmdEncoder = contextMtl->getComputeCommandEncoder();
    ASSERT(cmdEncoder);

    mtl::AutoObjCPtr<id<MTLComputePipelineState>> pipelineState =
        getTriFanFromElemArrayGeneratorPipeline(contextMtl, params.srcType, params.srcOffset);

    ASSERT(pipelineState);

    cmdEncoder->setComputePipelineState(pipelineState);

    ASSERT((params.dstOffset % kBufferSettingOffsetAlignment) == 0);
    ASSERT(params.indexCount > 2);

    IndexConversionUniform uniform;
    uniform.srcOffset  = params.srcOffset;
    uniform.indexCount = params.indexCount - 2;  // Only start from the 3rd element.

    cmdEncoder->setData(uniform, 0);
    cmdEncoder->setBuffer(params.srcBuffer, 0, 1);
    cmdEncoder->setBuffer(params.dstBuffer, params.dstOffset, 2);

    ANGLE_TRY(dispatchCompute(context, cmdEncoder, pipelineState, uniform.indexCount));

    return angle::Result::Continue;
}

angle::Result UtilsMtl::generateTriFanBufferFromClientElementsArray(
    const gl::Context *context,
    const TriFanFromClientElementArrayParams &params)
{
    switch (params.srcType)
    {
        case gl::DrawElementsType::UnsignedByte:
            return GenTriFanFromClientElements(context, params.indexCount,
                                               static_cast<const uint8_t *>(params.indices),
                                               params.dstBuffer, params.dstOffset);
        case gl::DrawElementsType::UnsignedShort:
            return GenTriFanFromClientElements(context, params.indexCount,
                                               static_cast<const uint16_t *>(params.indices),
                                               params.dstBuffer, params.dstOffset);
        case gl::DrawElementsType::UnsignedInt:
            return GenTriFanFromClientElements(context, params.indexCount,
                                               static_cast<const uint32_t *>(params.indices),
                                               params.dstBuffer, params.dstOffset);
        default:
            UNREACHABLE();
    }

    return angle::Result::Stop;
}

angle::Result UtilsMtl::dispatchCompute(const gl::Context *context,
                                        mtl::ComputeCommandEncoder *cmdEncoder,
                                        id<MTLComputePipelineState> pipelineState,
                                        size_t numThreads)
{
    NSUInteger w                  = pipelineState.threadExecutionWidth;
    MTLSize threadsPerThreadgroup = MTLSizeMake(w, 1, 1);

#if TARGET_OS_OSX
    if ([getMetalDevice() supportsFeatureSet:MTLFeatureSet_macOS_GPUFamily1_v1])
#else
    if ([getMetalDevice() supportsFeatureSet:MTLFeatureSet_iOS_GPUFamily4_v1])
#endif
    {
        MTLSize threads = MTLSizeMake(numThreads, 1, 1);
        cmdEncoder->dispatchNonUniform(threads, threadsPerThreadgroup);
    }
    else
    {
        MTLSize groups = MTLSizeMake((numThreads + w - 1) / w, 1, 1);
        cmdEncoder->dispatch(groups, threadsPerThreadgroup);
    }

    return angle::Result::Continue;
}

}  // namespace rx