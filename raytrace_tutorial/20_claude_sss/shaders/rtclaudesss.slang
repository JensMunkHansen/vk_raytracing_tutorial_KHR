/*
 * Copyright (c) 2023-2025, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-FileCopyrightText: Copyright (c) 2023-2025, NVIDIA CORPORATION.
 * SPDX-License-Identifier: Apache-2.0
 */

#include "common/shaders/pbr.h.slang"
#include "nvshaders/constants.h.slang"
#include "nvshaders/sky_functions.h.slang"
#include "shaderio.h"

// clang-format off
[[vk::push_constant]]                           ConstantBuffer<TutoPushConstant> pushConst;
[[vk::binding(BindingPoints::eTlas, 1)]]        RaytracingAccelerationStructure topLevelAS;
[[vk::binding(BindingPoints::eOutImage, 1)]]    RWTexture2D<float4> outImage;
// clang-format on

#define MISS_DEPTH 1000

//-----------------------------------------------------------------------
// RANDOM NUMBER GENERATION FOR RANDOM WALK SSS
//-----------------------------------------------------------------------
// Simple hash function for random numbers
uint hash(uint x)
{
  x += (x << 10u);
  x ^= (x >> 6u);
  x += (x << 3u);
  x ^= (x >> 11u);
  x += (x << 15u);
  return x;
}

uint hash2(uint2 v) { return hash(v.x ^ hash(v.y)); }
uint hash3(uint3 v) { return hash(v.x ^ hash(v.y) ^ hash(v.z)); }

// Generate random float in [0, 1)
float randomFloat(inout uint seed)
{
  seed = hash(seed);
  return float(seed) / 4294967296.0;
}

// Generate random direction on unit sphere
float3 randomSphereDirection(inout uint seed)
{
  float z = randomFloat(seed) * 2.0 - 1.0;
  float phi = randomFloat(seed) * 2.0 * M_PI;
  float r = sqrt(max(0.0, 1.0 - z * z));
  return float3(r * cos(phi), r * sin(phi), z);
}

//-----------------------------------------------------------------------
// RANDOM WALK SSS
// Traces rays that scatter inside the volume
//-----------------------------------------------------------------------
float3 randomWalkSSS(float3 entryPos, float3 entryNormal, float3 albedo, float scatterDist,
                     float3 lightDir, float3 lightColor, float lightIntensity, int maxBounces, uint seed)
{
  // Absorption coefficients - different for RGB to get color variation
  // Higher values = more absorption = less of that color in thick areas
  float3 sigma_a = float3(0.02, 0.05, 0.1) / scatterDist;  // Red scatters most, blue absorbs most
  float3 sigma_s = float3(1.0, 1.0, 1.0) / scatterDist;     // Scattering coefficient
  float3 sigma_t = sigma_a + sigma_s;  // Total extinction

  float3 throughput = float3(1.0, 1.0, 1.0);
  float3 result = float3(0.0, 0.0, 0.0);

  // Start inside the surface
  float3 pos = entryPos - entryNormal * 0.01;
  float3 dir = -entryNormal;  // Initial direction into surface

  for(int bounce = 0; bounce < maxBounces; bounce++)
  {
    // Sample distance based on mean free path
    float t = -log(max(0.0001, randomFloat(seed))) * scatterDist;

    // Move to new position
    float3 newPos = pos + dir * t;

    // Apply absorption along the path (Beer-Lambert)
    throughput *= exp(-sigma_a * t);

    // Check if we're still inside the object by tracing toward light
    RayQuery<RAY_FLAG_NONE> exitQuery;
    RayDesc exitRay;
    exitRay.Origin = newPos;
    exitRay.Direction = lightDir;
    exitRay.TMin = 0.0001;
    exitRay.TMax = scatterDist * 10.0;

    exitQuery.TraceRayInline(topLevelAS, RAY_FLAG_NONE, 0xff, exitRay);
    while(exitQuery.Proceed()) {}

    if(exitQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
    {
      // Still inside - continue scattering
      pos = newPos;

      // Pick new random direction (isotropic scattering)
      dir = randomSphereDirection(seed);
    }
    else
    {
      // Exited toward light - add light contribution
      float exitDist = t;
      result += throughput * albedo * lightColor * lightIntensity;
      break;
    }

    // Russian roulette termination
    float survivalProb = max(throughput.x, max(throughput.y, throughput.z));
    if(survivalProb < 0.001 || randomFloat(seed) > survivalProb)
      break;
    throughput /= survivalProb;
  }

  // Guard against NaN/INF from floating-point edge cases (denormal handling varies by driver)
  if(any(isnan(result)) || any(isinf(result)))
    result = float3(0.0, 0.0, 0.0);

  return result;
}

// Raytracing Payload for main rays
struct HitPayload
{
  float3 color;
  float  weight;
  int    depth;
};

// Payload for shadow rays with SSS transmission
struct ShadowPayload
{
  float3 transmission;  // Accumulated light transmission (RGB)
  float  totalThickness; // Total thickness traversed
  int    hitCount;       // Number of surfaces hit
};

// Hit state information
struct HitState
{
  float3 pos;
  float3 nrm;
  float3 geonrm;
};

__generic<T : IFloat> T getAttribute(uint8_t* dataBufferAddress, BufferView bufferView, uint attributeIndex)
{
  if(bufferView.count > 0)
  {
    T* ptr = (T*)(dataBufferAddress + bufferView.offset + attributeIndex * bufferView.byteStride);
    return ptr[0];
  }

  return T(1);  // Error case
}

int3 getTriangleIndices(uint8_t* dataBufferAddress, const TriangleMesh mesh, int primitiveID)
{
  if(mesh.indices.byteStride == sizeof(int16_t))
  {
    int16_t3* indices = (int16_t3*)(dataBufferAddress + mesh.indices.offset);
    return indices[primitiveID];
  }
  else if(mesh.indices.byteStride == sizeof(int32_t))
  {
    int3* indices = (int3*)(dataBufferAddress + mesh.indices.offset);
    return indices[primitiveID];
  }

  return int3(-1);  // Error case
}

__generic<T : IFloat> T getTriangleAttribute(uint8_t* dataBufferAddress, BufferView bufferView, uint3 attributeIndex, float3 barycentrics)
{
  T attr0 = getAttribute<T>(dataBufferAddress, bufferView, attributeIndex.x);
  T attr1 = getAttribute<T>(dataBufferAddress, bufferView, attributeIndex.y);
  T attr2 = getAttribute<T>(dataBufferAddress, bufferView, attributeIndex.z);
  return T(barycentrics.x) * attr0 + T(barycentrics.y) * attr1 + T(barycentrics.z) * attr2;
}


//-----------------------------------------------------------------------
// RAY GENERATION
//-----------------------------------------------------------------------
[shader("raygeneration")]
void rgenMain()
{
  float2 launchID   = (float2)DispatchRaysIndex().xy;
  float2 launchSize = (float2)DispatchRaysDimensions().xy;

  GltfSceneInfo* sceneInfo = pushConst.sceneInfoAddress;

  const uint   rayFlags   = RAY_FLAG_CULL_BACK_FACING_TRIANGLES;  // Cull back faces (normals point outward)
  const float2 clipCoords = launchID / launchSize * 2.0 - 1.0;
  const float4 viewCoords = mul(float4(clipCoords, 1.0, 1.0), sceneInfo.projInvMatrix);

  RayDesc ray;
  ray.Origin    = mul(float4(0.0, 0.0, 0.0, 1.0), sceneInfo.viewInvMatrix).xyz;
  ray.Direction = mul(float4(normalize(viewCoords.xyz), 0.0), sceneInfo.viewInvMatrix).xyz;
  ray.TMin      = 0.001;
  ray.TMax      = INFINITE;

  // Initial state
  HitPayload payload;
  payload.color  = float3(0, 0, 0);
  payload.weight = 1;
  payload.depth  = 0;

  TraceRay(topLevelAS, rayFlags, 0xff, 0, 0, 0, ray, payload);
  float3 color             = payload.color;
  outImage[int2(launchID)] = float4(color, 1.0);
}

//-----------------------------------------------------------------------
// SHADOW TESTING WITH ANY-HIT SHADER FOR SSS TRANSMISSION
//-----------------------------------------------------------------------
// Returns RGB transmission factor (how much light passes through)
float3 testShadowSSS(float3 worldPos, float3 worldNormal, float3 lightDirection, GltfPunctual light, float scatterDist)
{
  RayDesc shadowRay;
  shadowRay.Origin    = worldPos + worldNormal * 0.001;
  shadowRay.Direction = normalize(lightDirection);
  shadowRay.TMin      = 0.001;
  shadowRay.TMax      = light.type == GltfLightType::eDirectional ? INFINITE : length(lightDirection);

  // Initialize payload for SSS shadow
  ShadowPayload shadowPayload;
  shadowPayload.transmission = float3(1.0, 1.0, 1.0);  // Start fully lit
  shadowPayload.totalThickness = 0.0;
  shadowPayload.hitCount = 0;

  // Trace shadow ray - uses any-hit shader (hit group 1) and shadow miss shader (miss index 1)
  // RAY_FLAG_NONE allows any-hit shader to be called and potentially ignore hits
  TraceRay(topLevelAS, RAY_FLAG_NONE, 0xff, 1, 0, 1, shadowRay, shadowPayload);

  return shadowPayload.transmission;
}

// Simple binary shadow test (for non-SSS or performance mode)
float testShadow(float3 worldPos, float3 worldNormal, float3 lightDirection, GltfPunctual light)
{
  RayDesc shadowRay;
  shadowRay.Origin    = worldPos + worldNormal * 0.001;
  shadowRay.Direction = normalize(lightDirection);
  shadowRay.TMin      = 0.001;
  shadowRay.TMax      = light.type == GltfLightType::eDirectional ? INFINITE : length(lightDirection);

  // Use RayQuery for simple binary shadow test
  RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> shadowQuery;
  shadowQuery.TraceRayInline(topLevelAS, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff, shadowRay);
  while(shadowQuery.Proceed()) {}

  return shadowQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT ? 0.0 : 1.0;
}

//-----------------------------------------------------------------------
// THICKNESS COMPUTATION FOR SSS
// Traces a ray through the surface in the light direction to measure thickness
//-----------------------------------------------------------------------
float computeThickness(float3 worldPos, float3 worldNormal, float3 lightDir, float maxDistance)
{
  // Trace from the hit point opposite to light direction (into shadow)
  // This finds how thick the object is along the light path
  RayDesc thicknessRay;
  thicknessRay.Origin    = worldPos - worldNormal * 0.001;  // Start slightly inside
  thicknessRay.Direction = -lightDir;  // Trace opposite to light direction
  thicknessRay.TMin      = 0.0001;
  thicknessRay.TMax      = maxDistance;

  // Use RayQuery with front-face culling to only hit back faces (exit points)
  // This prevents hitting distant front-facing geometry through openings
  RayQuery<RAY_FLAG_CULL_FRONT_FACING_TRIANGLES> rayQuery;
  rayQuery.TraceRayInline(topLevelAS, RAY_FLAG_CULL_FRONT_FACING_TRIANGLES, 0xff, thicknessRay);

  while(rayQuery.Proceed())
  {
    // Accept any triangle hit
    if(rayQuery.CandidateType() == CANDIDATE_NON_OPAQUE_TRIANGLE)
    {
      rayQuery.CommitNonOpaqueTriangleHit();
    }
  }

  if(rayQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
  {
    return rayQuery.CommittedRayT();
  }

  return maxDistance;  // No exit found, assume maximum thickness
}

//-----------------------------------------------------------------------
// Handles sky override, point light distance attenuation, and spot light cone attenuation
//-----------------------------------------------------------------------
GltfPunctual processLight(GltfSceneInfo sceneInfo, float3 worldPos, float3 viewSpaceLightDir)
{
  GltfPunctual light;

  // Transform light direction from view space to world space (follows camera)
  // viewInvMatrix transforms from view space to world space
  float3 worldLightDir = normalize(mul(float4(viewSpaceLightDir, 0.0), sceneInfo.viewInvMatrix).xyz);

  light.direction = worldLightDir;
  light.color     = float3(1.0, 1.0, 1.0);
  light.intensity = 2.0;
  light.type      = GltfLightType::eDirectional;

  // Override with sky sun if enabled
  if(sceneInfo.useSky == 1)
  {
    light.direction = sceneInfo.skySimpleParam.sunDirection;
    light.color     = sceneInfo.skySimpleParam.sunColor;
    light.intensity = sceneInfo.skySimpleParam.sunIntensity;
  }

  // Point light: calculate direction and apply distance attenuation
  if(light.type == GltfLightType::ePoint)
  {
    light.direction = light.position - worldPos;
    float d         = length(light.direction);
    light.intensity /= (d * d);
  }
  // Spot light: calculate direction, apply distance and cone attenuation
  else if(light.type == GltfLightType::eSpot)
  {
    float3 lightDir = light.position - worldPos;
    float  d        = length(lightDir);
    light.intensity /= (d * d);
    // Cone attenuation
    float theta         = (dot(normalize(lightDir), normalize(light.direction)));
    float spotIntensity = clamp((theta - cos(light.coneAngle)) / (1.0 - cos(light.coneAngle)), 0.0, 1.0);
    light.intensity *= spotIntensity;
    light.direction = lightDir;
  }

  return light;
}

//-----------------------------------------------------------------------
// CLOSEST HIT
//-----------------------------------------------------------------------
[shader("closesthit")]
void rchitMain(inout HitPayload payload, in BuiltInTriangleIntersectionAttributes attr)
{
  float3 barycentrics = float3(1 - attr.barycentrics.x - attr.barycentrics.y, attr.barycentrics.x, attr.barycentrics.y);
  uint   instanceID   = InstanceIndex();
  uint   meshID       = InstanceID();
  uint   triID        = PrimitiveIndex();

  GltfSceneInfo         sceneInfo = pushConst.sceneInfoAddress[0];
  GltfInstance          instance  = sceneInfo.instances[instanceID];
  GltfMesh              mesh      = sceneInfo.meshes[instance.meshIndex];
  GltfMetallicRoughness material  = sceneInfo.materials[instance.materialIndex];

  // Retrieve the data
  int3   indices     = getTriangleIndices(mesh.gltfBuffer, mesh.triMesh, triID);
  float3 pos         = getTriangleAttribute<float3>(mesh.gltfBuffer, mesh.triMesh.positions, indices, barycentrics);
  float3 nrm         = getTriangleAttribute<float3>(mesh.gltfBuffer, mesh.triMesh.normals, indices, barycentrics);
  float3 worldPos    = float3(mul(float4(pos, 1.0), ObjectToWorld4x3()));
  float3 worldNormal = normalize(mul(WorldToObject4x3(), nrm).xyz);

  GltfPunctual light = processLight(sceneInfo, worldPos, pushConst.fixedLightDir);

  float3 V = -WorldRayDirection();
  float3 N = normalize(worldNormal);
  float3 L = normalize(light.direction);

  // Get base color from vertex color if available, otherwise use material
  float3 albedo = material.baseColorFactor.xyz;
  if(mesh.triMesh.colorVert.count > 0)
  {
    float4 vertColor = getTriangleAttribute<float4>(mesh.gltfBuffer, mesh.triMesh.colorVert, indices, barycentrics);
    albedo = vertColor.xyz;
  }

  // Get metallic and roughness from material
  float metallic  = material.metallicFactor;
  float roughness = material.roughnessFactor;
  if(pushConst.metallicRoughnessOverride.x >= 0.0)
    metallic = pushConst.metallicRoughnessOverride.x;
  if(pushConst.metallicRoughnessOverride.y >= 0.0)
    roughness = pushConst.metallicRoughnessOverride.y;

  // Simple diffuse lighting for better vertex color visibility
  float NdotL = max(dot(N, L), 0.0);

  // SSS parameters from push constants
  float sssStrength = pushConst.sssStrength;
  float scatterDist = pushConst.sssScatterDistance;

  // Compute thickness for SSS (needed for both debug and SSS calculation)
  float thickness = 0.0;
  if(sssStrength > 0.0)
  {
    thickness = computeThickness(worldPos, N, L, pushConst.sssMaxThickness);

    // Debug: Visualize thickness directly (red = thin, blue = thick)
    if(pushConst.showThickness != 0)
    {
      float debugThickness = clamp(thickness / scatterDist, 0.0, 1.0);
      payload.color = float3(1.0 - debugThickness, debugThickness * 0.5, debugThickness);
      return;
    }
  }

  float3 color;

  if(sssStrength > 0.0 && pushConst.sssQualityMode == 0)
  {
    // Fast mode: Use SSS shadow with any-hit transmission
    float3 shadowTransmission = testShadowSSS(worldPos, N, light.direction, light, scatterDist);

    // Direct lighting modulated by SSS shadow transmission
    float3 directLight = albedo * NdotL * light.color * light.intensity * shadowTransmission;
    float3 ambientLight = albedo * 0.3;

    color = directLight + ambientLight;

    // Thickness-based SSS
    float normalizedThickness = thickness / scatterDist;
    float transmission = exp(-normalizedThickness * 2.0);

    // SSS tint (warm for skin/teeth)
    float3 sssColor = float3(1.0, 0.7, 0.5);

    // Main SSS: light transmitting through thin areas
    float3 sssContribution = albedo * sssColor * transmission * light.color * light.intensity * sssStrength;

    // Back-lighting effect
    float backLight = max(0.0, -dot(N, L));
    float3 backLightContribution = albedo * sssColor * backLight * transmission * light.color * light.intensity * sssStrength * 2.0;

    // Wrap lighting for softer diffuse
    float wrapFactor = 0.3 * sssStrength;
    float wrappedNdotL = (dot(N, L) + wrapFactor) / (1.0 + wrapFactor);
    float3 wrapContribution = albedo * max(0.0, wrappedNdotL) * transmission * sssStrength * 0.5;

    color += sssContribution + backLightContribution + wrapContribution;
  }
  else
  {
    // Quality mode (random walk) or no SSS: use simple binary shadow
    float shadowFactor = testShadow(worldPos, N, light.direction, light);

    float3 directLight = albedo * NdotL * light.color * light.intensity * shadowFactor;
    float3 ambientLight = albedo * 0.3;

    color = directLight + ambientLight;

    if(sssStrength > 0.0)
    {
      // Quality mode: Random walk SSS
      uint seed = hash3(uint3(DispatchRaysIndex().xy, uint(WorldRayOrigin().x * 1000.0)));
      float3 rwSSS = randomWalkSSS(worldPos, N, albedo, scatterDist, L, light.color, light.intensity, pushConst.sssMaxBounces, seed);
      color += rwSSS * sssStrength;
    }
  }

  payload.color = color;
}

//-----------------------------------------------------------------------
// ANY-HIT SHADOW - Called at each intersection for SSS transmission
//-----------------------------------------------------------------------
[shader("anyhit")]
void rahitShadowMain(inout ShadowPayload payload, in BuiltInTriangleIntersectionAttributes attr)
{
  // Get scatter distance from push constants
  float scatterDist = pushConst.sssScatterDistance;

  // Absorption coefficients - same as in random walk SSS
  // Red scatters most (lowest absorption), blue absorbs most
  float3 sigma_a = float3(0.02, 0.05, 0.1) / scatterDist;

  // Estimate local thickness at this intersection point
  // For a simple approximation, use a fixed thickness per surface crossing
  // A more accurate method would trace through the geometry
  float localThickness = scatterDist * 0.5;  // Approximate half scatter distance per surface

  // Apply Beer-Lambert absorption
  float3 absorption = exp(-sigma_a * localThickness);
  payload.transmission *= absorption;

  // Track total thickness and hit count
  payload.totalThickness += localThickness;
  payload.hitCount++;

  // If transmission is very low, accept the hit and stop (fully shadowed)
  float maxTransmission = max(payload.transmission.r, max(payload.transmission.g, payload.transmission.b));
  if(maxTransmission < 0.01)
  {
    AcceptHitAndEndSearch();
    return;
  }

  // Otherwise, ignore this hit and continue to find more intersections
  // This allows the ray to pass through and accumulate more absorption
  IgnoreHit();
}

//-----------------------------------------------------------------------
// MISS - Main miss shader for primary rays
//-----------------------------------------------------------------------
[shader("miss")]
void rmissMain(inout HitPayload payload)
{
  GltfSceneInfo* sceneInfo = pushConst.sceneInfoAddress;

  if(sceneInfo.useSky == 1)
  {
    float3 skyColor = evalSimpleSky(sceneInfo.skySimpleParam, WorldRayDirection());
    payload.color += skyColor * payload.weight;
  }
  else
  {
    payload.color += sceneInfo.backgroundColor * payload.weight;
  }

  payload.depth = MISS_DEPTH;  // Stop
}

//-----------------------------------------------------------------------
// SHADOW MISS - Dedicated miss shader for shadow rays
//-----------------------------------------------------------------------
[shader("miss")]
void rmissShadowMain(inout ShadowPayload payload)
{
  // Ray reached the light without being fully absorbed
  // Transmission remains as accumulated by any-hit shader
  // (already set correctly, nothing to do)
}
