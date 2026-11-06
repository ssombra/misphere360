#ifndef StitcherCore_h
#define StitcherCore_h

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Cose una foto de doble ojo de pez (Dual Fisheye 6912x3456) en una imagen equirrectangular 360° usando las tablas LUT de calibración óptica de fábrica.
/// Retorna 0 si tuvo éxito, o un código negativo en caso de error.
int stitch_dual_fisheye_c(const char *in_jpg_path, const char *lut_bin_path, const char *out_jpg_path);

#ifdef __cplusplus
}
#endif

#endif /* StitcherCore_h */
