#ifndef URP_SCREEN_SPACE_PATH_TRACING_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_HLSL

#include "./PathTracingUtilities.hlsl"

// If no intersection, "rayHit.distance" will remain "REAL_EPS".
RayHit RayMarching(Ray ray, half insideObject, half dither, half3 viewDirectionWS, half sceneDistance = 0.0)
{
    RayHit rayHit = InitializeRayHit();

    // True:  The ray points to the scene objects.
    // False: The ray points to the camera plane.
    bool isFrontRay = (dot(ray.direction, viewDirectionWS) <= 0.0) ? true : false;

    // Store a frequently used material property
    half stepSize = STEP_SIZE;

    // Initialize small step ray marching settings
    half thickness = MARCHING_THICKNESS_SMALL_STEP;
    half currStepSize = SMALL_STEP_SIZE;

    // Minimum thickness of scene objects without backface depth
    half marchingThickness = MARCHING_THICKNESS;

    // Initialize current ray position.
    float3 rayPositionWS = ray.position;

    // Interpolate the intersecting position using the depth difference.
    float lastDepthDiff = 0.0;
    //float2 lastRayPositionNDC = float2(0.0, 0.0);
    float3 lastRayPositionWS = ray.position; // avoid using 0 for the first interpolation

    bool startBinarySearch = false;

    // Adaptive Ray Marching
    // Near: Use smaller step size to improve accuracy.
    // Far:  Use larger step size to fill the scene.
    bool activeSamplingSmall = true;
    bool activeSamplingMedium = true;

    UNITY_LOOP
    for (int i = 1; i <= MAX_STEP; i++)
    {
        if (i > MAX_SMALL_STEP && i <= MAX_MEDIUM_STEP && activeSamplingSmall)
        {
            activeSamplingSmall = false;
            currStepSize = (startBinarySearch) ? currStepSize : MEDIUM_STEP_SIZE;
            thickness = (startBinarySearch) ? thickness : MARCHING_THICKNESS_MEDIUM_STEP;
            marchingThickness = MARCHING_THICKNESS;
        }
        else if (i > MAX_MEDIUM_STEP && !activeSamplingSmall && activeSamplingMedium)
        {
            activeSamplingMedium = false;
            // [Far] Use a small step size only when objects are close to the camera.
            currStepSize = (startBinarySearch) ? currStepSize : lerp(stepSize, 20.0, sceneDistance * 0.001);
            thickness = (startBinarySearch) ? thickness : MARCHING_THICKNESS;
            marchingThickness = MARCHING_THICKNESS;
        }

        // Update current ray position.
        rayPositionWS += (currStepSize + currStepSize * dither) * ray.direction;

        float3 rayPositionNDC = ComputeNormalizedDeviceCoordinatesWithZ(rayPositionWS, GetWorldToHClipMatrix());
        float3 lastRayPositionNDC = ComputeNormalizedDeviceCoordinatesWithZ(lastRayPositionWS, GetWorldToHClipMatrix());

        // Move to the next step if the current ray moves less than 1 pixel across the screen.
        if (i <= MAX_MEDIUM_STEP && abs(rayPositionNDC.x - lastRayPositionNDC.x) < _BlitTexture_TexelSize.x && abs(rayPositionNDC.y - lastRayPositionNDC.y) < _BlitTexture_TexelSize.y)
            continue;

    #if (UNITY_REVERSED_Z == 0) // OpenGL platforms
        rayPositionNDC.z = rayPositionNDC.z * 0.5 + 0.5; // -1..1 to 0..1
    #endif

        // Stop marching the ray when outside screen space.
        bool isScreenSpace = rayPositionNDC.x > 0.0 && rayPositionNDC.y > 0.0 && rayPositionNDC.x < 1.0 && rayPositionNDC.y < 1.0 ? true : false;
        if (!isScreenSpace)
            break;

        // Sample the 3-layer depth
        float deviceDepth; // z buffer (front) depth
    #if defined(_BACKFACE_TEXTURES)
        if (insideObject == 1.0 && _SupportRefraction)
            // Transparent Depth Layer 2
            deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraBackDepthTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
        else if (insideObject == 2.0 && _SupportRefraction)
            // Opaque Depth Layer
            deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
        else
            // Transparent Depth Layer 1
            deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
    #else
        if (insideObject != 0.0 && _SupportRefraction)
            // Opaque Depth Layer
            deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
        else
            // Transparent Depth Layer 1
            deviceDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
    #endif

        // Convert Z-Depth to Linear Eye Depth
        // Value Range: Camera Near Plane -> Camera Far Plane
        float sceneDepth = LinearEyeDepth(deviceDepth, _ZBufferParams);
        float hitDepth = LinearEyeDepth(rayPositionNDC.z, _ZBufferParams); // Non-GL (DirectX): rayPositionNDC.z is (near to far) 1..0

        // Calculate (front) depth difference
        // Positive: ray is in front of the front-faces of object.
        // Negative: ray is behind the front-faces of object.
        float depthDiff = sceneDepth - hitDepth;

        // Initialize variables
        float deviceBackDepth = 0.0; // z buffer (back) depth
        float sceneBackDepth = 0.0;

        // Calculate (back) depth difference
        // Positive: ray is in front of the back-faces of object.
        // Negative: ray is behind the back-faces of object.
        float backDepthDiff = 0.0;

        // Avoid infinite thickness for objects with no thickness (ex. Plane).
        // 1. Back-face depth value is not from sky
        // 2. Back-faces should behind Front-faces.
        bool backDepthValid = false; 
    #if defined(_BACKFACE_TEXTURES)
        if (insideObject == 1.0 && _SupportRefraction)
            deviceBackDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
        else
            deviceBackDepth = SAMPLE_TEXTURE2D_X_LOD(_CameraBackDepthTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).r;
        sceneBackDepth = LinearEyeDepth(deviceBackDepth, _ZBufferParams);

        backDepthValid = (deviceBackDepth != UNITY_RAW_FAR_CLIP_VALUE) && (sceneBackDepth >= sceneDepth);

        if (backDepthValid)
            backDepthDiff = hitDepth - sceneBackDepth;
        else
            backDepthDiff = depthDiff - marchingThickness;
    #endif

        // Binary Search Sign is used to flip the ray marching direction.
        // Sign is positive : ray is in front of the actual intersection.
        // Sign is negative : ray is behind the actual intersection.
        half Sign;
        bool isBackSearch = (!isFrontRay && hitDepth > sceneBackDepth && backDepthValid);
        if (isBackSearch)
            Sign = FastSign(backDepthDiff);
        else
            Sign = FastSign(depthDiff);

        // Disable binary search:
        // 1. The ray points to the camera plane, but is in front of all objects.
        // 2. The ray leaves the camera plane, but is behind all objects.
        // 3. The ray is an outgoing (refracted) ray. (we only have 3-layer depth)
        bool cannotBinarySearch = (insideObject != 2.0) && !startBinarySearch && (isFrontRay ? hitDepth > sceneBackDepth : hitDepth < sceneDepth);

        // Start binary search when the ray is behind the actual intersection.
        startBinarySearch = !cannotBinarySearch && (startBinarySearch || (Sign == -1)) ? true : false;

        // Half the step size each time when binary search starts.
        // If the ray passes through the intersection, we flip the sign of step size.
        if (startBinarySearch)
        {
            currStepSize *= 0.5;
            currStepSize = (FastSign(currStepSize) == Sign) ? currStepSize : -currStepSize;
        }

        // Do not reflect sky, use reflection probe fallback.
        bool isSky = sceneDepth == UNITY_RAW_FAR_CLIP_VALUE ? true : false;

        // [No minimum step limit] The current implementation focuses on performance, so the ray will stop marching once it hits something.
        // Rules of ray hit:
        // 1. Ray is behind the front-faces of object. (sceneDepth <= hitDepth)
        // 2. Ray is in front of back-faces of object. (sceneBackDepth >= hitDepth) or (sceneDepth + marchingThickness >= hitDepth)
        // 3. Ray does not hit sky. (!isSky)
        bool hitSuccessful;
        bool isBackHit = false;

        // Ignore the incorrect "backDepthDiff" when objects (ex. Plane with front face only) has no thickness and blocks the backface depth rendering of objects behind it.
    #if defined(_BACKFACE_TEXTURES)
        UNITY_BRANCH
        if (backDepthValid)
        {
            // It's difficult to find the intersection of thin objects in several steps with large step sizes, so we add a minimum thickness to all objects to make it visually better.
            hitSuccessful = ((depthDiff <= 0.0) && (hitDepth <= max(sceneBackDepth, sceneDepth + currStepSize)) && !isSky) ? true : false;
            //hitSuccessful = !isSky && (isFrontRay && (depthDiff <= 0.1 && depthDiff >= -0.1) || !isFrontRay && (hitDepth <= max(sceneBackDepth , sceneDepth + MARCHING_THICKNESS) + 0.1 && hitDepth >= max(sceneBackDepth, sceneDepth + MARCHING_THICKNESS) - 0.1)) ? true : false;
            isBackHit = hitDepth > sceneBackDepth && Sign > 0.0;
        }
        else
    #endif
        {
            hitSuccessful = ((depthDiff <= 0.0) && (depthDiff >= -marchingThickness) && !isSky) ? true : false;
        }

        // If we find the intersection.
        if (hitSuccessful)
        {
            rayHit.position = rayPositionWS;
            rayHit.distance = length(rayPositionWS - ray.position);
            rayHit.insideObject = insideObject;

            // Lerp the world space position according to depth difference.
            // From https://baddogzz.github.io/2020/03/06/Accurate-Hit/
            // 
            // x: position from last marching
            // y: current ray marching position (successfully hit the scene)
            //           |
            // Cam->--x--|-y
            //           |
            // Using the position between "x" and "y" is more accurate than using "y" directly.
            if (Sign != FastSign(lastDepthDiff))
            {
                // Seems that interpolating screenUV is giving worse results, so do it for positionWS only.
                float interpDepthDiff = (isBackSearch) ? backDepthDiff : depthDiff;
                //rayPositionNDC.xy = lerp(lastRayPositionNDC, rayPositionNDC.xy, lastDepthDiff * rcp(lastDepthDiff - interpDepthDiff));
                rayHit.position = lerp(lastRayPositionWS, rayHit.position, lastDepthDiff * rcp(lastDepthDiff - interpDepthDiff));
            }
            
            // Get the material data of the hit position.
            HitSurfaceDataFromGBuffer(rayPositionNDC.xy, rayHit);
            
            // Reverse the normal direction since it's a back face.
            // Reuse the front face GBuffer to save performance.
        #if defined(_BACKFACE_TEXTURES)
            if (isBackHit && _BackDepthEnabled == 2.0)
            {
                half3 backNormal = SAMPLE_TEXTURE2D_X_LOD(_CameraBackNormalsTexture, my_point_clamp_sampler, rayPositionNDC.xy, 0).rgb;
                if (any(backNormal))
                    rayHit.normal = -backNormal; // Accurate (refraction)
                else
                    rayHit.normal = -rayHit.normal; // Approximate
            }
            else if (isBackHit)
                rayHit.normal = -rayHit.normal; // Approximate
        #endif

            // Add position offset to avoid self-intersection, we don't know the next ray direction yet.
            rayHit.position += rayHit.normal * RAY_BIAS;

            break;
        }
        // [Optimization] Exponentially increase the stepSize when the ray hasn't passed through the intersection.
        // From https://blog.voxagon.se/2018/01/03/screen-space-path-tracing-diffuse.html
        else if (!startBinarySearch)
        {
            // As the distance increases, the accuracy of ray intersection test becomes less important.
            currStepSize += currStepSize * 0.1;
            marchingThickness += MARCHING_THICKNESS * 0.25;
        }

        // Update last step's depth difference.
        lastDepthDiff = (isBackSearch) ? backDepthDiff : depthDiff;
        //lastRayPositionNDC = rayPositionNDC.xy;
        lastRayPositionWS = rayPositionWS.xyz;
    }
    return rayHit;
}

// === Hi-Z Min-Max Tracing ===========================================
// Cell-based hierarchical traversal (GPU Pro 5 / Stingray / AMD FidelityFX SSSR style):
// the ray is advanced through screen-space texel cells using a fully parametric
// ray/cell-boundary and ray/depth-plane intersection test, not point-sampling. Within a
// cell the ray's depth changes continuously as it moves in X/Y, so comparing one
// interpolated depth sample against the cell's stored bounds is not sufficient - what
// matters is which happens FIRST as the ray advances: leaving the cell's XY footprint,
// or reaching the cell's nearest-possible-occluder depth plane. Both are solved in
// closed form (as ray parameter t, in mip0-pixel units) and compared directly.
//
// NDC device depth is affine in screen-space distance along a straight 2D screen-space
// line (the same property that lets rasterizer hardware z-interpolate linearly across a
// triangle without perspective correction), so the depth-plane crossing has an exact
// closed-form solution - no iterative refinement needed. Because mip 0's stored bounds
// ARE the exact per-pixel front/back depth (see HiZDepthPyramid.shader's Init pass), and
// a hit is only ever accepted once the traversal has descended all the way to mip 0, the
// returned hit position is already exact to the depth buffer's own texel resolution -
// there is no fixed-size step grid and no precision gap between samples for a binary
// search to recover. Only used for primary rays (insideObject == 0); refraction rays
// keep using RayMarching above, since they rely on its 3-layer depth-stack handling.

bool HiZIsBehindOrAt(float rayDepth, float surfaceDepth)
{
#if UNITY_REVERSED_Z
    return rayDepth <= surfaceDepth;
#else
    return rayDepth >= surfaceDepth;
#endif
}

// Solves for the ray parameter t (>= currentT) at which the ray's depth first becomes
// "behind or at" targetDepth (see HiZIsBehindOrAt), or returns a very large sentinel if
// that never happens for the remainder of the ray.
//
// A ray's depth does not necessarily move away from the camera for its whole length - it
// can curve back toward it (e.g. near-grazing bounces off a steeply angled surface). Once
// the ray is confirmed NOT behind targetDepth yet, whether it can EVER become behind it
// later depends on which way its depth is moving relative to the active depth convention:
//  - moving in the "away" direction (reversed-Z: depth decreasing; otherwise increasing):
//    the ray is closing in on targetDepth and WILL cross it at the algebraic solution,
//    which is guaranteed to lie ahead of currentT.
//  - moving in the "toward camera" direction: the ray is moving further from ever
//    satisfying HiZIsBehindOrAt against this specific target - it can only have been
//    behind it in the past (already handled by the "currently behind" check above), never
//    in the future, so this cell can never register a hit going forward and must be
//    reported as unreachable (the sentinel), not solved for.
// Treating both directions with the same closed-form formula silently assumes the first
// case always holds; for the second case the algebraic solution lands in the past, and
// naively clamping it forward to currentT turns every step of a toward-camera ray into a
// false immediate hit - exactly the "reflections cut off at grazing angles" bug this
// function exists to avoid.
float HiZSolveDepthCrossing(float currentT, float currentDepth, float targetDepth,
                             float startDepth, float deltaDepth, float invDeltaDepth, float distPx)
{
    if (HiZIsBehindOrAt(currentDepth, targetDepth))
        return currentT;

    if (abs(deltaDepth) <= 1e-8)
        return 1e8; // Depth does not change along the ray - it will never reach a different value.

#if UNITY_REVERSED_Z
    bool approachingTarget = deltaDepth < 0.0;
#else
    bool approachingTarget = deltaDepth > 0.0;
#endif
    if (!approachingTarget)
        return 1e8;

    return max((targetDepth - startDepth) * invDeltaDepth * distPx, currentT);
}

// Complementary to HiZSolveDepthCrossing: given the ray is CURRENTLY behind targetDepth,
// solves for the t (>= currentT) at which it will surface back out of that state, or
// returns a large sentinel if it stays behind for the rest of the ray. A ray moving away
// from the camera that is already behind a given depth stays behind it forever
// (monotonically decreasing depth never comes back) - only a ray curving back toward the
// camera can surface out again, which is exactly the direction HiZSolveDepthCrossing
// treats as "never enters". Without this, a coarse cell's "past everything" state (see
// HiZClassifyOcclusion) would be assumed to persist until the ray leaves the cell in XY,
// silently skipping over the point where a toward-camera ray re-emerges mid-cell.
float HiZSolveDepthExit(float currentT, float startDepth, float targetDepth,
                         float deltaDepth, float invDeltaDepth, float distPx)
{
    if (abs(deltaDepth) <= 1e-8)
        return 1e8; // Depth never changes - if already behind, stays behind forever.

#if UNITY_REVERSED_Z
    bool recedingFromTarget = deltaDepth > 0.0;
#else
    bool recedingFromTarget = deltaDepth < 0.0;
#endif
    if (!recedingFromTarget)
        return 1e8;

    return max((targetDepth - startDepth) * invDeltaDepth * distPx, currentT);
}

// Occlusion classification for a Hi-Z cell, using the pyramid's real per-pixel front/back
// depth bounds (see SampleHiZLevel) instead of an assumed thickness: minMax.y is the
// nearest possible entry surface in the cell, minMax.x is the farthest possible exit
// surface. Both are exact worst-case bounds for the whole cell (never an approximation),
// so once the ray is behind minMax.x it is guaranteed to have cleared every occluder the
// cell could contain - no uncertainty remains that would require rejecting a later hit as
// unreliable.
//
// Returns true when the ray's current depth lies between the two bounds - real opaque
// geometry may occupy this depth range, so the caller either descends the hierarchy to
// confirm or, at mip 0 (exact per-pixel data), accepts it as a hit outright. Returns
// false otherwise, with outEventT receiving the future t (>= currentT) at which the ray
// would next cross into that range - via HiZSolveDepthCrossing if still in front of
// minMax.y, or via HiZSolveDepthExit if already behind minMax.x and only reachable again
// by curving back toward the camera - or a large sentinel if that never happens for the
// remainder of the ray.
bool HiZClassifyOcclusion(float currentT, float currentDepth, float2 minMax,
                           float startDepth, float deltaDepth, float invDeltaDepth, float distPx,
                           out float outEventT)
{
    if (!HiZIsBehindOrAt(currentDepth, minMax.y))
    {
        outEventT = HiZSolveDepthCrossing(currentT, currentDepth, minMax.y, startDepth, deltaDepth, invDeltaDepth, distPx);
        return false;
    }

    if (HiZIsBehindOrAt(currentDepth, minMax.x))
    {
        outEventT = HiZSolveDepthExit(currentT, startDepth, minMax.x, deltaDepth, invDeltaDepth, distPx);
        return false;
    }

    outEventT = currentT;
    return true;
}

// Clamps the world-space marching distance so ray.position + ray.direction * distance
// never crosses (or gets numerically close to) the camera's near plane. Projecting to NDC
// via a perspective divide is only well-behaved in front of the camera: as a point
// approaches the near plane, w -> 0 and its projected screen position/depth blow up
// toward infinity, then flip sign once actually behind it. Rays routinely curve back
// toward the camera at grazing angles (viewDirVS.z > 0), so this is a real, reachable
// case - the ray must be clipped the same way a rasterizer clips triangles against the
// near plane before the perspective divide, rather than trusting the raw max-distance
// endpoint to always be safely projectable.
float HiZClipDistanceToNearPlane(float3 originVS, float3 dirVS, float maxDistance)
{
    if (unity_OrthoParams.w > 0.5 || dirVS.z <= 0.0)
        return maxDistance; // Orthographic has no perspective singularity; moving away
                             // from the camera never approaches the near plane.

    // Small safety margin so w stays comfortably away from zero, not just non-negative.
    float nearZ = -_ProjectionParams.y * 1.05;
    float distToNearPlane = (nearZ - originVS.z) / dirVS.z;
    return clamp(distToNearPlane, 0.0, maxDistance);
}

// World-space Hi-Z traversal for primary rays. Ray/RayHit-compatible with RayMarching
// above. There is no fixed step grid to dither - every hit is an exact closed-form
// crossing point.
RayHit HiZTracing(Ray ray)
{
    RayHit rayHit = InitializeRayHit();

    float3 originVS = TransformWorldToView(ray.position);
    float3 dirVS = TransformWorldToViewDir(ray.direction, true);
    float clippedDistance = HiZClipDistanceToNearPlane(originVS, dirVS, _HiZMaxDistance);

    float3 startSS = ComputeNormalizedDeviceCoordinatesWithZ(ray.position, GetWorldToHClipMatrix());
    float3 endSS = ComputeNormalizedDeviceCoordinatesWithZ(ray.position + ray.direction * clippedDistance, GetWorldToHClipMatrix());
#if (UNITY_REVERSED_Z == 0) // OpenGL platforms: match RayMarching's own -1..1 -> 0..1 remap.
    startSS.z = startSS.z * 0.5 + 0.5;
    endSS.z = endSS.z * 0.5 + 0.5;
#endif

    float2 realSize = _HiZScreenSize.xy;
    float2 startPx = startSS.xy * realSize;
    float2 endPx = endSS.xy * realSize;

    float2 deltaPx = endPx - startPx;
    float distPx = length(deltaPx);
    if (distPx < 1.0)
        return rayHit;

    float2 dir = deltaPx / distPx;
    // Cell-boundary math divides by direction components - keep them safely non-zero.
    float2 safeDir = float2(
        abs(dir.x) < 1e-5 ? (dir.x < 0.0 ? -1e-5 : 1e-5) : dir.x,
        abs(dir.y) < 1e-5 ? (dir.y < 0.0 ? -1e-5 : 1e-5) : dir.y);

    float deltaDepth = endSS.z - startSS.z;
    bool depthVaries = abs(deltaDepth) > 1e-8;
    float invDeltaDepth = depthVaries ? (1.0 / deltaDepth) : 0.0;

    // A fixed small starting offset (in pixels) is enough to avoid self-intersection with
    // the reflecting surface itself. HiZTracing does not sample at discrete fixed-size
    // steps - every hit is an exact closed-form crossing point, so there is no fixed step
    // grid for per-pixel jitter to dither/de-band.
    float t = 1.0;

    int maxLevel = max((int)_HiZLevelCount - 1, 0);
    int level = 0;
    int iterCount = min((int)_HiZMaxSteps, HIZ_MAX_ITER);

    UNITY_LOOP
    for (int i = 0; i < HIZ_MAX_ITER; i++)
    {
        if (i >= iterCount || t >= distPx)
            break;

        float2 pos = startPx + dir * t;
        if (pos.x < 0.0 || pos.x >= realSize.x || pos.y < 0.0 || pos.y >= realSize.y)
            return rayHit; // Clean miss: ray left the visible screen.

        // UV is resolution-independent, so it must always be normalized against the BASE
        // (level 0) padded canvas size, never the current level's own (smaller) size -
        // _HiZMipInfo[level] only describes that level's texel count, not a valid UV
        // denominator for a "pos" given in base-resolution pixel units.
        float2 uvPyramid = pos / _HiZMipInfo[0].xy;
        float2 minMax = SampleHiZLevel(uvPyramid, level);

        float currentDepth = lerp(startSS.z, endSS.z, saturate(t / distPx));
        float tEvent;
        bool isCandidate = HiZClassifyOcclusion(t, currentDepth, minMax, startSS.z,
                                                 deltaDepth, invDeltaDepth, distPx, tEvent);

        // t at which the ray leaves the current cell's XY footprint.
        float cellSize = (float)(1u << level);
        float2 cellIndex = floor(pos / cellSize);
        float2 boundary = (cellIndex + step(0.0, safeDir)) * cellSize;
        float2 tAxis = (boundary - startPx) / safeDir;
        float tCell = max(min(tAxis.x, tAxis.y), t);

        if (isCandidate)
        {
            // Between the cell's real front/back depth bounds - opaque geometry may
            // occupy this range.
            if (level == 0)
            {
                // Mip 0 stores exact per-pixel front/back depth (no cell aggregation left
                // to be uncertain about) - the ray is genuinely between this pixel's own
                // front and back surface, i.e. inside solid opaque geometry. Always an
                // outright hit.
                float2 hitUV = pos / realSize;
                float hitDepth = currentDepth;
            #if (UNITY_REVERSED_Z == 0)
                // Inverse of the forward GL remap above, matching ScreenSpacePathTracing.shader's frag().
                hitDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, hitDepth);
            #endif
                float3 hitPositionWS = ComputeWorldSpacePosition(hitUV, hitDepth, UNITY_MATRIX_I_VP);

                rayHit.position = hitPositionWS;
                rayHit.distance = distance(hitPositionWS, ray.position);
                rayHit.insideObject = 0.0;

                HitSurfaceDataFromGBuffer(hitUV, rayHit);

                // Add position offset to avoid self-intersection, we don't know the next ray direction yet.
                rayHit.position += rayHit.normal * RAY_BIAS;

                return rayHit;
            }

            level--;
        }
        else
        {
            // Clearly outside the cell's occupied depth range (either not reached yet, or
            // already past every occluder the cell could contain) - skip ahead to the
            // next event using the same tEvent/tCell logic either way.
            if (tEvent < tCell)
            {
                // Will enter the occlusion window before leaving this cell - jump straight
                // to it and re-classify there next iteration.
                t = tEvent + 0.05;
            }
            else
            {
                // Clear for the remainder of this cell - climb the hierarchy.
                t = tCell + 0.05;
                level = min(level + 1, maxLevel);
            }
        }
    }

    return rayHit; // Miss: search budget exhausted.
}

half3 EvaluateBRDF(inout Ray ray, RayHit rayHit, float3 positionWS, float2 screenUV)
{
    // If the ray intersects the scene.
    if (rayHit.distance > REAL_EPS)
    {
        // Incoming Ray Direction
        half3 viewDirectionWS = -ray.direction;
        half NdotV = ClampNdotV(dot(rayHit.normal, viewDirectionWS));

        // Probabilities of each lobe
        bool doRefraction = (rayHit.ior == -1.0) ? false : true;
        half refractProbability = doRefraction ? ReflectivitySpecular(rayHit.albedo) : 0.0;
        half specProbability = doRefraction ? 1.0 - refractProbability : ReflectivitySpecular(max(rayHit.specular, kDieletricSpec.rgb));
        half diffProbability = (1.0 - specProbability - refractProbability);

        half perceptualRoughness = 1.0 - rayHit.smoothness;
        half roughness = perceptualRoughness * perceptualRoughness;

        float2 random = float2(GenerateRandomValue(screenUV), GenerateRandomValue(screenUV));
        half3x3 localToWorld = GetLocalFrame(rayHit.normal);

        // Roulette-select the ray's path.
        half roulette = GenerateRandomValue(screenUV);

        // TODO: reimplement the refraction to match Disney BSDF
        UNITY_BRANCH
        if (refractProbability > 0.0 && roulette < refractProbability)
        {
            // Refraction
            rayHit.ior = rayHit.insideObject == 1.0 ? rcp(rayHit.ior) : rayHit.ior; // (air / material) : (material / air)

            half VdotH;
            half NdotH;
            SampleGGXNDF(random, viewDirectionWS, localToWorld, roughness, rayHit.normal, NdotH, VdotH);

            half fresnel = F_Schlick(0.04, max(rayHit.smoothness, 0.04), VdotH);

            half3 refractDir = refract(ray.direction, rayHit.normal, rayHit.ior);
            // Null vector check.
            if (any(refractDir) && roulette > fresnel)
            {
                ray.direction = refractDir;
            }
            // Total Internal Reflection && Specular Reflection
            else
            {
                ray.direction = reflect(ray.direction, rayHit.normal);
            }
            ray.position = rayHit.position;
            // Absorption
            if (rayHit.insideObject == 2.0) // Exit refractive object
                ray.energy *= rcp(max(refractProbability, 0.001)) * exp(rayHit.albedo * max(rayHit.distance, 2.5)); // Artistic: add a minimum color absorption distance.
            else if (rayHit.insideObject == 1.0) // apply the tint here if the ray needs to fall back to reflection probe
                ray.energy *= rcp(max(refractProbability, 0.001)) * rayHit.albedo;
        }
        else if (specProbability > 0.0 && roulette < specProbability)
        {
            // Note: H is the microfacet normal direction

            half VdotH;
            half NdotL;
            half3 L;
            half weightOverPdf;

            ImportanceSampleGGX_PDF(random, viewDirectionWS, localToWorld, roughness, NdotV, L, VdotH, NdotL, weightOverPdf);

            half3 F = F_Schlick(rayHit.specular, VdotH);

            // Outgoing Ray Direction
            ray.direction = L;
            ray.position = rayHit.position;

            half3 brdf = F;

            // Fresnel component is apply here as describe in ImportanceSampleGGX function
            ray.energy *= rcp(specProbability) * brdf * weightOverPdf;
        }
        else if (diffProbability > 0.0 && roulette < diffProbability)
        {
            half3 L;
            half NdotL;
            half weightOverPdf;

            // for Disney we still use a Cosine importance sampling, true Disney importance sampling imply a look up table
            ImportanceSampleLambert(random, localToWorld, L, NdotL, weightOverPdf);
            
            // Outgoing Ray Direction
            ray.direction = L;
            ray.position = rayHit.position;

            // For fixed luminance lighting units in URP, we don't need to do the PI division
        #if USE_DISNEY_DIFFUSE
            half LdotV = saturate(dot(ray.direction, viewDirectionWS));

            half3 brdf = rayHit.albedo * DisneyDiffuseNoPI(NdotV, NdotL, LdotV, perceptualRoughness);
        #else
            half3 brdf = rayHit.albedo * LambertNoPI(); // "LambertNoPI()" is "1.0"
        #endif
            
            ray.energy *= rcp(diffProbability) * brdf * weightOverPdf;
        }
        else
        {
            // Terminate ray
            ray.energy = 0.0;
        }

        return rayHit.emission;
    }
    // If no intersection from ray marching.
    else
    {
        // Erase the ray's energy - the sky doesn't reflect anything.
        ray.energy = 0.0;

        // Forward or Deferred:
        // URP won't set correct reflection probe for a full screen blit mesh. (issue ID: UUM-2631)
        // The reflection probe(s) is set by a C# script attached to the Camera.
        // The script won't get the correct probe for scene camera, it'll use game camera's instead.

        // Forward+:
        // Sample the reflection probe atlas.

        // Reflection Probes Fallback
        half3 color = SampleReflectionProbes(ray.direction, positionWS, 1.0h, screenUV);
        return color;
    }
}

void ScreenSpacePathTracing(float depth, float3 positionWS, float3 cameraPositionWS, half3 viewDirectionWS, float2 screenUV, out half3 color)
{
    // Skip if sky
    bool isBackground = depth == UNITY_RAW_FAR_CLIP_VALUE ? true : false;

    // Dither the step size to reduce banding artifacts.
    half dither = 0.0;
    UNITY_BRANCH
    if (_Dithering)
    {
    #if defined(_RAY_MARCHING_VERY_LOW)
        // Double the dither intensity if ray marching quality is set to very low (large STEP_SIZE).
        dither = (GenerateRandomValue(screenUV) * 0.4 - 0.2) * _Dither_Intensity; // Range from -0.2 to 0.2 (assuming intensity is 1)
    #else
        dither = (GenerateRandomValue(screenUV) * 0.2 - 0.1) * _Dither_Intensity; // Range from -0.1 to 0.1 (assuming intensity is 1)
    #endif
    }

    // Ignore ForwardOnly objects, the GBuffer MaterialFlags cannot help distinguish them.
    // Current solution is to assume objects with 0 smoothness are ForwardOnly. (DepthNormalsOnly pass will output 0 to gbuffer2.a)
    // Which means Deferred objects should have at least 0.01 smoothness.
    bool isForwardOnly = false;

#if defined(_TEMPORAL_ACCUMULATION)
    half historySample = SAMPLE_TEXTURE2D_X_LOD(_PathTracingSampleTexture, my_point_clamp_sampler, screenUV, 0).r;
#endif
    half rayCount = RAY_COUNT;

    UNITY_LOOP
    for (int i = 0; i < rayCount; i++)
    {
        RayHit rayHit = InitializeRayHit(); // should be reinitialized for each sample.
        half roughnessBias = 0.0;
        Ray ray;
        ray.position = cameraPositionWS;
        ray.direction = -viewDirectionWS; // viewDirectionWS points to the camera.
        ray.energy = half3(1.0, 1.0, 1.0);

        // [No ray marching needed] We already know the result of first hit, since it goes from the camera to scene.
        {
            rayHit.distance = length(cameraPositionWS - positionWS);
            rayHit.position = positionWS;

            HitSurfaceDataFromGBuffer(screenUV, rayHit);

        #if defined(_TEMPORAL_ACCUMULATION)
            if (rayHit.smoothness > 0.5 || historySample == 1.0)
                rayCount = max(RAY_COUNT_LOW_SAMPLE, RAY_COUNT); // Cast more rays if the history sample is low.
        #endif

        #if defined(_IGNORE_FORWARD_OBJECTS)
            isForwardOnly = rayHit.smoothness == 0.0 ? true : false;
        #endif
            if (isForwardOnly && !isBackground)
            {
                color = rayHit.emission;
                break;
            }
            else
            {
                // Firefly reduction
                // From https://twitter.com/YuriyODonnell/status/1199253959086612480
                // Seems to be no difference, need to dig deeper later.
                half oldRoughness = (1.0 - rayHit.smoothness);
                oldRoughness = oldRoughness * oldRoughness;
                half modifiedRoughness = min(1.0, oldRoughness + roughnessBias);
                //rayHit.smoothness = 1.0 - sqrt(modifiedRoughness);
                roughnessBias += oldRoughness * 0.75;

                // energy * emission * SPP accumulation factor
                color += ray.energy * EvaluateBRDF(ray, rayHit, positionWS, screenUV) * rcp(rayCount);
            }
        }

        // Other bounces.
        UNITY_LOOP
        for (int j = 0; j < RAY_BOUNCE; j++)
        {
            half sceneDistance = rayHit.distance * 0.1;
            depth = LinearEyeDepth(depth, _ZBufferParams);
        #if defined(_HIZ_TRACING)
            if (rayHit.insideObject == 0.0)
                rayHit = HiZTracing(ray);
            else
                rayHit = RayMarching(ray, rayHit.insideObject, dither, viewDirectionWS, depth);
        #else
            rayHit = RayMarching(ray, rayHit.insideObject, dither, viewDirectionWS, depth);
        #endif

            // Firefly reduction
            // From https://twitter.com/YuriyODonnell/status/1199253959086612480
            // Seems to be no difference, need to dig deeper later.
            half oldRoughness = (1.0 - rayHit.smoothness);
            oldRoughness = oldRoughness * oldRoughness;
            half modifiedRoughness = min(1.0, oldRoughness + roughnessBias);
            //rayHit.smoothness = 1.0 - sqrt(modifiedRoughness);
            roughnessBias += oldRoughness * 0.75;

            color += ray.energy * EvaluateBRDF(ray, rayHit, positionWS, screenUV) * rcp(rayCount);

            if (!any(ray.energy))
                break;

            // Russian Roulette - Randomly terminate rays.
            // From https://blog.demofox.org/2020/06/06/casual-shadertoy-path-tracing-2-image-improvement-and-glossy-reflections/
            // As the throughput gets smaller, the ray is more likely to get terminated early.
            // Survivors have their value boosted to make up for fewer samples being in the average.
            half stopRayEnergy = GenerateRandomValue(screenUV);

            half maxRayEnergy = Max3(ray.energy.r, ray.energy.g, ray.energy.b);

            if (maxRayEnergy < stopRayEnergy)
                break;

            // Add the energy we 'lose' by randomly terminating paths.
            ray.energy *= rcp(maxRayEnergy);
        }
    }
}

#endif