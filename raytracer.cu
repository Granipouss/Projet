// [header]
// A very basic raytracer example.
// [/header]
// [compile]
// c++ -o raytracer -O3 -Wall raytracer.cpp
// [/compile]
// [ignore]
// Copyright (C) 2012  www.scratchapixel.com
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
// [/ignore]
#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <cuda_runtime.h>
#include <vector_types.h>
#include "cutil_math.h"


#if defined __linux__ || defined __APPLE__
  // "Compiled for Linux
#else
  // Windows doesn't define these values by default, Linux does
  #define M_PI 3.14159265359f  // pi
  #define INFINITY 1e8
#endif

#define width 1280  // screenwidth
#define height 1024 // screenheight
#define tileSize 16
#define MaxRayDepth 5 // This variable controls the maximum recursion depth

#define nbSpheres 100

// = Utils ===

inline float clamp (float x) { return x < 0.0f ? 0.0f : x > 1.0f ? 1.0f : x; }
inline int toInt (float x) { return int(clamp(x) * 255 + .5); }
inline float randF (float min, float max) { return min + (((float) rand()) / (float) RAND_MAX) * (max - min); }

// = Struct ===

struct Sphere {
  float3 center;                      /// position of the sphere
  // float radius, radius2;           /// sphere radius and radius^2
  float radius2;                      /// sphere radius^2
  float3 surfaceColor, emissionColor; /// surface color and emission (light)
  float transparency, reflection;     /// surface transparency and reflectivity

  // Compute a ray-sphere intersection using the geometric solution
  __device__ bool intersect (float3 rayorig, float3 raydir, float &t0, float &t1) const {
    float3 l = center - rayorig;
    float tca = dot(l, raydir);
    if (tca < 0) return false;
    float d2 = dot(l, l) - tca * tca;
    if (d2 > radius2) return false;
    float thc = sqrt(radius2 - d2);
    t0 = tca - thc;
    t1 = tca + thc;

    return true;
  }
};

__constant__ Sphere spheres[nbSpheres + 2];

__device__ float mix(const float &a, const float &b, const float &mix) {
  return b * mix + a * (1 - mix);
}

// This is the main trace function. It takes a ray as argument (defined by its origin
// and direction). We test if this ray intersects any of the geometry in the scene.
// If the ray intersects an object, we compute the intersection point, the normal
// at the intersection point, and shade this point using this information.
// Shading depends on the surface property (is it transparent, reflective, diffuse).
// The function returns a color for the ray. If the ray intersects an object that
// is the color of the object at the intersection point, otherwise it returns
// the background color.
__device__ float3 trace(
  const float3 rayorig,
  const float3 raydir,
  const int &depth
) {
  // if (raydir.length() != 1) std::cerr << "Error " << raydir << std::endl;
  float tnear = INFINITY;
  const Sphere* sphere = NULL;
  // find intersection of this ray with the sphere in the scene
  for (unsigned i = 0; i < nbSpheres + 2; ++i) {
    float t0 = INFINITY, t1 = INFINITY;
    if (spheres[i].intersect(rayorig, raydir, t0, t1)) {
      if (t0 < 0) t0 = t1;
      if (t0 < tnear) {
        tnear = t0;
        sphere = &spheres[i];
      }
    }
  }
  // if there's no intersection return black or background color
  if (!sphere) return make_float3(2);
  float3 surfaceColor = make_float3(0); // color of the ray/surfaceof the object intersected by the ray
  float3 phit = rayorig + raydir * tnear; // point of intersection
  float3 nhit = phit - sphere->center; // normal at the intersection point
  nhit = normalize(nhit); // normalize normal direction
  // If the normal and the view direction are not opposite to each other
  // reverse the normal direction. That also means we are inside the sphere so set
  // the inside bool to true. Finally reverse the sign of IdotN which we want
  // positive.
  float bias = 1e-4; // add some bias to the point from which we will be tracing
  bool inside = false;
  if (dot(raydir, nhit) > 0) nhit = -nhit, inside = true;

  if ((sphere->transparency > 0 || sphere->reflection > 0) && depth < MaxRayDepth) {
    float facingratio = -dot(raydir, nhit);
    // change the mix value to tweak the effect
    float fresneleffect = mix(pow(1 - facingratio, 3), 1, 0.1);
    // compute reflection direction (not need to normalize because all vectors
    // are already normalized)
    float3 refldir = raydir - nhit * 2 * dot(raydir, nhit);
    refldir = normalize(refldir);
    float3 reflection = trace(phit + nhit * bias, refldir, depth + 1);
    float3 refraction = make_float3(0);
    // if the sphere is also transparent compute refraction ray (transmission)
    if (sphere->transparency) {
      float ior = 1.1, eta = (inside) ? ior : 1 / ior; // are we inside or outside the surface?
      float cosi = -dot(nhit, raydir);
      float k = 1 - eta * eta * (1 - cosi * cosi);
      float3 refrdir = raydir * eta + nhit * (eta *  cosi - sqrt(k));
      refrdir = normalize(refrdir);
      refraction = trace(phit - nhit * bias, refrdir, depth + 1);
    }
    // the result is a mix of reflection and refraction (if the sphere is transparent)
    surfaceColor = (
      reflection * fresneleffect +
      refraction * (1 - fresneleffect) * sphere->transparency
    ) * sphere->surfaceColor;
  } else {
    // it's a diffuse object, no need to raytrace any further
    for (unsigned i = 0; i < nbSpheres + 2; ++i) {
      if (spheres[i].emissionColor.x > 0) {
        // this is a light
        float3 transmission = make_float3(1);
        float3 lightDirection = spheres[i].center - phit;
        lightDirection = normalize(lightDirection);
        for (unsigned j = 0; j < nbSpheres + 2; ++j) {
          if (i != j) {
            float t0, t1;
            if (spheres[j].intersect(phit + nhit * bias, lightDirection, t0, t1)) {
              transmission = make_float3(0);
              break;
            }
          }
        }
        surfaceColor +=
          sphere->surfaceColor * transmission *
          max(float(0), dot(nhit, lightDirection)) * spheres[i].emissionColor;
      }
    }
  }

  return surfaceColor + sphere->emissionColor;
}

__constant__ const float invWidth = 1 / float(width);
__constant__ const float invHeight = 1 / float(height);
__constant__ const float aspectratio = width / float(height);

__global__ void render_kernel (float3 *image) {
  float fov = 30.0f;
  float angle = tan(M_PI * 0.5 * fov / 180.0f);

  unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
  unsigned int y = blockIdx.y * blockDim.y + threadIdx.y;
  unsigned int i = y * width + x;
  if (x > width || y > height) return;

  float xx = (2 * ((x + 0.5) * invWidth) - 1) * angle * aspectratio;
  float yy = (1 - 2 * ((y + 0.5) * invHeight)) * angle;
  float3 raydir = make_float3(xx, yy, -1);
  raydir = normalize(raydir);

  image[i] = trace(make_float3(0), raydir, 0);
}

// Main rendering function. We compute a camera ray for each pixel of the image
// trace it and return a color. If the ray hits a sphere, we return the color of the
// sphere at the intersection point, else we return the background color.
void render () {
  // Create image
  float3* image_h = new float3[width * height];
  float3* image_d;
  cudaMalloc(&image_d, width * height * sizeof(float3));

  // Trace rays
  dim3 block(tileSize, tileSize, 1);
  dim3 grid(width / tileSize, height / tileSize, 1);
  render_kernel <<<grid, block>>> (image_d);
  cudaMemcpy(image_h, image_d, width * height *sizeof(float3), cudaMemcpyDeviceToHost);
  cudaFree(image_d);

  // Save result to a PPM image (keep these flags if you compile under Windows)
  std::ofstream ofs("./untitled.ppm", std::ios::out | std::ios::binary);
  ofs << "P6\n" << width << " " << height << "\n255\n";
  for (unsigned i = 0; i < width * height; ++i) {
    ofs << (unsigned char) toInt(image_h[i].x) <<
           (unsigned char) toInt(image_h[i].y) <<
           (unsigned char) toInt(image_h[i].z);
  }
  ofs.close();
  delete [] image_h;
}

// In the main function, we will create the scene which is composed of 5 spheres
// and 1 light (which is also a sphere). Then, once the scene description is complete
// we render that scene, by calling the render() function.
int main(int argc, char **argv) {
  srand48(13);
  // Create scene on host
  Sphere *scene_h = new Sphere[nbSpheres + 2];
  // Spheres
  // float3 center, float radius2, float3 surfaceColor, float3 emissionColor, float transparency, float reflection
  scene_h[0] = { make_float3(0, -10004,  -2), 1e8, make_float3(0.2f), make_float3(0), 0, 0 }; // Background
  scene_h[1] = { make_float3(0,     20, -30),   9, make_float3(0.0f), make_float3(3), 0, 0 }; // Light
  for ( int i = 0; i < nbSpheres; ++i ) {

    float x,y,z,rd,r,b,g,t;
    x = (rand()/(1.*RAND_MAX))*20.-10.;
    y = (rand()/(1.*RAND_MAX))*2.-1.;
    z = (rand()/(1.*RAND_MAX))*10.-25.;
    rd = (rand()/(1.*RAND_MAX))*0.9+0.1;
    r  = (rand()/(1.*RAND_MAX));
    g  = (rand()/(1.*RAND_MAX));
    b  = (rand()/(1.*RAND_MAX));
    t  = (rand()/(1.*RAND_MAX))*0.5;
    scene_h[2 + i] = { make_float3(x, y, z), rd * rd, make_float3(r, g, b), make_float3(0), t, 1 };

    // float rd = randF(0.1f, 1.0f);
    // float tr = randF(0.5f, 1.0f);
    // float re = randF(0.0f, 1.0f);
    // float3 center = make_float3(randF(-10, 10), randF(-1, 1), randF(-25, -15));
    // float3 color = make_float3(randF(0, 1), randF(0, 1), randF(0, 1));
    // scene_h[2 + i] = { center, rd * rd, color, make_float3(0), tr, re };
  }
  // Copy the host's scene to a device constante
  cudaMemcpyToSymbol(spheres,  scene_h, (nbSpheres + 2) * sizeof(Sphere));
  delete[] scene_h;
  // Render the scene
  render();

  return 0;
}
