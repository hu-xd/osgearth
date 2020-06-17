#version 430
layout(local_size_x=1, local_size_y=1, local_size_z=1) in;

#pragma include GroundCover.Types.glsl

// LUT methods generated by GroundCoverLayer.cpp
struct oe_gc_LandCoverGroup {
    int firstAssetIndex;
    int numAssets;
    float fill;
};
struct oe_gc_Asset {
    int assetId;
    int modelId;
    int modelSamplerIndex;
    int sideSamplerIndex;
    int topSamplerIndex;
    float width;
    float height;
    float radius;
    float sizeVariation;
    float fill;
};
bool oe_gc_getLandCoverGroup(in int zone, in int code, out oe_gc_LandCoverGroup result);
bool oe_gc_getAsset(in int index, out oe_gc_Asset result);

uniform sampler2D oe_gc_noiseTex;
#define NOISE_SMOOTH   0
#define NOISE_RANDOM   1
#define NOISE_RANDOM_2 2
#define NOISE_CLUMPY   3

// (LLx, LLy, URx, URy, tileNum
uniform float oe_tile[5];
uniform int oe_gc_zone;

uniform vec2 oe_tile_elevTexelCoeff;
uniform sampler2D oe_tile_elevationTex;
uniform mat4 oe_tile_elevationTexMatrix;
uniform float oe_GroundCover_colorMinSaturation;

#pragma import_defines(OE_LANDCOVER_TEX)
#pragma import_defines(OE_LANDCOVER_TEX_MATRIX)
uniform sampler2D OE_LANDCOVER_TEX;
uniform mat4 OE_LANDCOVER_TEX_MATRIX;

#pragma import_defines(OE_GROUNDCOVER_MASK_SAMPLER)
#pragma import_defines(OE_GROUNDCOVER_MASK_MATRIX)
#ifdef OE_GROUNDCOVER_MASK_SAMPLER
uniform sampler2D OE_GROUNDCOVER_MASK_SAMPLER;
uniform mat4 OE_GROUNDCOVER_MASK_MATRIX;
#endif

#pragma import_defines(OE_GROUNDCOVER_COLOR_SAMPLER)
#pragma import_defines(OE_GROUNDCOVER_COLOR_MATRIX)
#ifdef OE_GROUNDCOVER_COLOR_SAMPLER
uniform sampler2D OE_GROUNDCOVER_COLOR_SAMPLER ;
uniform mat4 OE_GROUNDCOVER_COLOR_MATRIX ;
#endif

#pragma import_defines(OE_GROUNDCOVER_PICK_NOISE_TYPE)
#ifdef OE_GROUNDCOVER_PICK_NOISE_TYPE
int pickNoiseType = OE_GROUNDCOVER_PICK_NOISE_TYPE ;
#else
int pickNoiseType = NOISE_RANDOM;
//int pickNoiseType = NOISE_CLUMPY;
#endif

#ifdef OE_GROUNDCOVER_COLOR_SAMPLER
// https://stackoverflow.com/a/17897228/4218920
vec3 rgb2hsv(vec3 c)
{
    const vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    const float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

bool isLegalColor(in vec2 tilec)
{
    vec4 c = texture(OE_GROUNDCOVER_COLOR_SAMPLER, (OE_GROUNDCOVER_COLOR_MATRIX*vec4(tilec,0,1)).st);
    vec3 hsv = rgb2hsv(c.rgb);
    return hsv[1] > oe_GroundCover_colorMinSaturation;
}
#endif // OE_GROUNDCOVER_COLOR_SAMPLER

float getElevation(in vec2 tilec) {
    vec2 elevc = tilec
        * oe_tile_elevTexelCoeff.x * oe_tile_elevationTexMatrix[0][0] // scale
        + oe_tile_elevTexelCoeff.x * oe_tile_elevationTexMatrix[3].st // bias
        + oe_tile_elevTexelCoeff.y;
    return texture(oe_tile_elevationTex, elevc).r;
}

void generate()
{
    const uint x = gl_GlobalInvocationID.x;
    const uint y = gl_GlobalInvocationID.y;

    uint tileNum = uint(oe_tile[4]);

    uint local_i =
        gl_GlobalInvocationID.y * gl_NumWorkGroups.x
        + gl_GlobalInvocationID.x;
    uint i = 
        tileNum * (gl_NumWorkGroups.x * gl_NumWorkGroups.y)
        + local_i;

    instance[i].instanceId = 0; // means the slot is unoccupied
    instance[i].tileNum = tileNum; // need this for merge

    vec2 offset = vec2(float(x), float(y));
    vec2 halfSpacing = 0.5 / vec2(gl_NumWorkGroups.xy);
    vec2 tilec = halfSpacing + offset / vec2(gl_NumWorkGroups.xy);

    vec4 noise = textureLod(oe_gc_noiseTex, tilec, 0);

    vec2 shift = vec2(fract(noise[1]*1.5), fract(noise[2]*1.5))*2.0-1.0;
    tilec += shift * halfSpacing;

    vec4 tilec4 = vec4(tilec, 0, 1);

#ifdef OE_GROUNDCOVER_COLOR_SAMPLER
    if (!isLegalColor(tilec))
        return;
#endif

    // sample the landcover data
    int code = int(textureLod(OE_LANDCOVER_TEX, (OE_LANDCOVER_TEX_MATRIX*tilec4).st, 0).r);    
    oe_gc_LandCoverGroup group;
    if (oe_gc_getLandCoverGroup(oe_gc_zone, code, group) == false)
        return;

    // If we're using a mask texture, sample it now:
#ifdef OE_GROUNDCOVER_MASK_SAMPLER
    float mask = texture(OE_GROUNDCOVER_MASK_SAMPLER, (OE_GROUNDCOVER_MASK_MATRIX*tilec4).st).a;
    if ( mask > 0.0 )
        return;
#endif

    // discard instances based on noise value threshold (coverage). If it passes,
    // scale the noise value back up to [0..1]
    if (noise[NOISE_SMOOTH] > group.fill)
        return;
    noise[NOISE_SMOOTH] /= group.fill;

    // select a billboard at random
    float pickNoise = 1.0-noise[pickNoiseType];
    int assetIndex = group.firstAssetIndex + int(floor(pickNoise * float(group.numAssets)));
    assetIndex = min(assetIndex, group.firstAssetIndex + group.numAssets - 1);

    // Recover the asset we randomly picked:
    oe_gc_Asset asset;
    oe_gc_getAsset(assetIndex, asset);

    // asset fill:
    if (noise[NOISE_RANDOM_2] > asset.fill)
        return;

    // It's a keeper - record it to the instance buffer.

    vec2 LL = vec2(oe_tile[0], oe_tile[1]);
    vec2 UR = vec2(oe_tile[2], oe_tile[3]);

    vec4 vertex_model = vec4(mix(LL, UR, tilec), getElevation(tilec), 1.0);

    instance[i].vertex = vertex_model;
    instance[i].tilec = tilec;

    instance[i].fillEdge = 1.0;
    const float xx = 0.5;
    if (noise[NOISE_SMOOTH] > xx)
        instance[i].fillEdge = 1.0-((noise[NOISE_SMOOTH]-xx)/(1.0-xx));

    instance[i].modelId = asset.modelId;

    instance[i].modelSamplerIndex = asset.modelSamplerIndex;
    instance[i].sideSamplerIndex = asset.sideSamplerIndex;
    instance[i].topSamplerIndex = asset.topSamplerIndex;

    //a pseudo-random scale factor to the width and height of a billboard
    instance[i].sizeScale = 1.0 + asset.sizeVariation * (noise[NOISE_RANDOM_2]*2.0-1.0);
    instance[i].width = asset.width * instance[i].sizeScale;
    instance[i].height = asset.height * instance[i].sizeScale;
    instance[i].radius = asset.radius;

    //float rotation = 6.283185 * noise[NOISE_RANDOM];
    float rotation = 6.283185 * fract(noise[NOISE_RANDOM_2]*5.5);
    instance[i].sinrot = sin(rotation);
    instance[i].cosrot = cos(rotation);

    // non-zero instanceID means this slot is occupied
    instance[i].instanceId = 1 + int(i);
}


// Consolidates all the instances made by generate()
void merge()
{
    uint i = gl_GlobalInvocationID.x;

    // only if instance is set and tile is active:
    if (instance[i].instanceId > 0 && tileData[instance[i].tileNum].inUse == 1)
    {
        uint k = atomicAdd(di.num_groups_x, 1);
        instanceLUT[k] = i;
    }
}


uniform vec3 oe_VisibleLayer_ranges;
uniform vec3 oe_Camera;
uniform int oe_gc_numCommands; // total number of draw commands
uniform float oe_gc_sse = 100.0; // pixels

void cull()
{
    uint i = instanceLUT[ gl_GlobalInvocationID.x ];

    // initialize to -1, meaning the instance will be ignored.
    instance[i].drawId = -1;

    // Which tile did this come from
    uint tileNum = instance[i].tileNum;

    // Bring into view space:
    vec4 vertex_view = tileData[tileNum].modelViewMatrix * instance[i].vertex;

    float range = -vertex_view.z;
    float maxRange = oe_VisibleLayer_ranges[1] / oe_Camera.z;

    // distance culling:
    if (range >= maxRange)
        return;

    // frustum culling:
    vec4 clipLL = gl_ProjectionMatrix * (vertex_view - vec4(instance[i].radius, 0, 0, 0));
    clipLL.xy /= clipLL.w;
    if (clipLL.x > 1.0 || clipLL.y > 1.0)
        return;

    vec4 clipUR = gl_ProjectionMatrix * (vertex_view + vec4(instance[i].radius, 2*instance[i].radius, 0, 0));
    clipUR.xy /= clipUR.w;
    if (clipUR.x < -1.0 || clipUR.y < -1.0)
        return;

    // Model versus billboard selection:
    bool chooseModel = instance[i].modelId >= 0;

    // If model, make sure we're within the SSE limit:
    vec2 pixelSizeRatio = vec2(1);
    if (chooseModel)
    {
        vec2 pixelSize = 0.5*(clipUR.xy-clipLL.xy) * oe_Camera.xy;
        pixelSizeRatio = pixelSize / vec2(oe_gc_sse);
        if (all(lessThan(pixelSizeRatio, vec2(1))))
            chooseModel = false;
    }

    // If we chose a billboard but there isn't one, bail.
    if (chooseModel == false && instance[i].sideSamplerIndex < 0)
        return;

    // "drawId" is the index of the DrawElementsIndirect command we will
    // use to draw this instance. Command[0] is the billboard group; all
    // others are unique 3D models.
    instance[i].drawId = chooseModel ? instance[i].modelId + 1 : 0;

    instance[i].pixelSizeRatio = min(pixelSizeRatio.x, pixelSizeRatio.y);

    // for each command FOLLOWING the one we just picked,
    // increment the baseInstance number. We should end up with
    // the correct baseInstance for each command by the end of the cull pass.
    for (uint drawId = instance[i].drawId + 1; drawId < oe_gc_numCommands; ++drawId)
    {
        atomicAdd(cmd[drawId].baseInstance, 1);
    }
}


void sort()
{
    uint i = instanceLUT[gl_GlobalInvocationID.x];

    int drawId = instance[i].drawId;
    if (drawId >= 0)
    {
        // find the index of the first instance for this bin:
        uint cmdStartIndex = cmd[drawId].baseInstance;

        // bump the instance count for this command; the new instanceCount
        // is also the index within the command:
        uint instanceIndex = atomicAdd(cmd[drawId].instanceCount, 1);

        // copy to the right place in the render list
        uint index = cmdStartIndex + instanceIndex;
        renderLUT[index] = i;
    }
}

uniform int oe_pass;

#define PASS_GENERATE 0
#define PASS_MERGE 1
#define PASS_CULL 2
#define PASS_SORT 3

void main()
{
    if (oe_pass == PASS_GENERATE)
        generate();
    else if (oe_pass == PASS_MERGE)
        merge();
    else if (oe_pass == PASS_CULL)
        cull();
    else // if (oe_pass == PASS_SORT)
        sort();
}