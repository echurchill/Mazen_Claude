import MetalKit

#if !targetEnvironment(simulator)
/// Metal-4 pipeline / depth-state / shadow-map / sampler construction (R2.8 — extracted verbatim
/// from Renderer's init, which had grown ~130 lines of one-time setup around the frame loop; logic
/// unchanged). All `try!`/`!` here are deliberate fail-fast-at-launch, as before: a machine that
/// can't build these can't run the game at all.
enum PipelineFactory {

    /// The main maze pipeline — MSAA, alpha-blended (fog/dissolve layers draw through it too).
    static func makeMazePipeline(compiler: MTL4Compiler, library: MTLLibrary,
                                 sampleCount: Int, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
        let vertFuncDesc = MTL4LibraryFunctionDescriptor()
        vertFuncDesc.library = library
        vertFuncDesc.name = "vertexShader"
        let fragFuncDesc = MTL4LibraryFunctionDescriptor()
        fragFuncDesc.library = library
        fragFuncDesc.name = "fragmentShader"

        let pipeDesc = MTL4RenderPipelineDescriptor()
        pipeDesc.label = "MazePipeline"
        pipeDesc.rasterSampleCount = sampleCount
        pipeDesc.vertexFunctionDescriptor = vertFuncDesc
        pipeDesc.fragmentFunctionDescriptor = fragFuncDesc
        pipeDesc.colorAttachments[0].pixelFormat = colorFormat
        pipeDesc.colorAttachments[0].blendingState = .enabled
        pipeDesc.colorAttachments[0].rgbBlendOperation = .add
        pipeDesc.colorAttachments[0].alphaBlendOperation = .add
        pipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try! compiler.makeRenderPipelineState(descriptor: pipeDesc)
    }

    /// The fullscreen sky pass (also the vertex stage the fade overlay reuses).
    static func makeSkyPipeline(compiler: MTL4Compiler, library: MTLLibrary,
                                sampleCount: Int, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
        let skyVertDesc = MTL4LibraryFunctionDescriptor()
        skyVertDesc.library = library
        skyVertDesc.name = "skyVertexShader"
        let skyFragDesc = MTL4LibraryFunctionDescriptor()
        skyFragDesc.library = library
        skyFragDesc.name = "skyFragmentShader"

        let skyPipeDesc = MTL4RenderPipelineDescriptor()
        skyPipeDesc.label = "SkyPipeline"
        skyPipeDesc.rasterSampleCount = sampleCount
        skyPipeDesc.vertexFunctionDescriptor = skyVertDesc
        skyPipeDesc.fragmentFunctionDescriptor = skyFragDesc
        skyPipeDesc.colorAttachments[0].pixelFormat = colorFormat
        return try! compiler.makeRenderPipelineState(descriptor: skyPipeDesc)
    }

    /// Fade pipeline (M11.2b): reuses the sky fullscreen triangle, alpha-blended over the scene.
    static func makeFadePipeline(compiler: MTL4Compiler, library: MTLLibrary,
                                 sampleCount: Int, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
        let skyVertDesc = MTL4LibraryFunctionDescriptor()
        skyVertDesc.library = library
        skyVertDesc.name = "skyVertexShader"
        let fadeFragDesc = MTL4LibraryFunctionDescriptor()
        fadeFragDesc.library = library
        fadeFragDesc.name = "fadeFragmentShader"

        let fadePipeDesc = MTL4RenderPipelineDescriptor()
        fadePipeDesc.label = "FadePipeline"
        fadePipeDesc.rasterSampleCount = sampleCount
        fadePipeDesc.vertexFunctionDescriptor = skyVertDesc
        fadePipeDesc.fragmentFunctionDescriptor = fadeFragDesc
        fadePipeDesc.colorAttachments[0].pixelFormat = colorFormat
        fadePipeDesc.colorAttachments[0].blendingState = .enabled
        fadePipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        fadePipeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        fadePipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        fadePipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try! compiler.makeRenderPipelineState(descriptor: fadePipeDesc)
    }

    /// Shadow pipeline (depth-only, no fragment).
    static func makeShadowPipeline(compiler: MTL4Compiler, library: MTLLibrary) -> MTLRenderPipelineState {
        let shadowVertDesc = MTL4LibraryFunctionDescriptor()
        shadowVertDesc.library = library
        shadowVertDesc.name = "shadowVertexShader"

        let shadowPipeDesc = MTL4RenderPipelineDescriptor()
        shadowPipeDesc.label = "ShadowPipeline"
        shadowPipeDesc.rasterSampleCount = 1
        shadowPipeDesc.vertexFunctionDescriptor = shadowVertDesc
        return try! compiler.makeRenderPipelineState(descriptor: shadowPipeDesc)
    }

    /// M20 — alpha-tested shadow pipeline for cut-out foliage (adds a fragment stage that discards
    /// transparent texels). Kept separate from the depth-only pipeline above so only the handful of
    /// cut-out sub-meshes pay for a fragment shader; everything else keeps the fast path.
    static func makeShadowCutoutPipeline(compiler: MTL4Compiler, library: MTLLibrary) -> MTLRenderPipelineState {
        let vert = MTL4LibraryFunctionDescriptor()
        vert.library = library
        vert.name = "shadowCutoutVertexShader"
        let frag = MTL4LibraryFunctionDescriptor()
        frag.library = library
        frag.name = "shadowCutoutFragmentShader"

        let desc = MTL4RenderPipelineDescriptor()
        desc.label = "ShadowCutoutPipeline"
        desc.rasterSampleCount = 1
        desc.vertexFunctionDescriptor = vert
        desc.fragmentFunctionDescriptor = frag
        return try! compiler.makeRenderPipelineState(descriptor: desc)
    }

    /// Shadow map texture (2048×2048 — keeps texel density up as the ortho volume
    /// grows with cube size; a 9-face jamb/wall is only a few texels at 1024).
    static func makeShadowMap(device: MTLDevice) -> MTLTexture {
        let shadowDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        shadowDesc.storageMode = .private
        shadowDesc.usage = [.renderTarget, .shaderRead]
        let tex = device.makeTexture(descriptor: shadowDesc)!
        tex.label = "ShadowMap"
        return tex
    }

    /// The three depth-stencil states the passes cycle through: scene (write), translucent
    /// (test, no write), and sky/fade (always, no write).
    static func makeDepthStates(device: MTLDevice)
        -> (write: MTLDepthStencilState, noWrite: MTLDepthStencilState, always: MTLDepthStencilState) {
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        let write = device.makeDepthStencilState(descriptor: depthDesc)!

        let depthDescNoWrite = MTLDepthStencilDescriptor()
        depthDescNoWrite.depthCompareFunction = .less
        depthDescNoWrite.isDepthWriteEnabled = false
        let noWrite = device.makeDepthStencilState(descriptor: depthDescNoWrite)!

        let depthDescAlways = MTLDepthStencilDescriptor()
        depthDescAlways.depthCompareFunction = .always
        depthDescAlways.isDepthWriteEnabled = false
        let always = device.makeDepthStencilState(descriptor: depthDescAlways)!
        return (write, noWrite, always)
    }

    /// The one shared repeat/linear sampler.
    static func makeSampler(device: MTLDevice) -> MTLSamplerState {
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .repeat
        samplerDesc.tAddressMode = .repeat
        return device.makeSamplerState(descriptor: samplerDesc)!
    }
}
#endif
