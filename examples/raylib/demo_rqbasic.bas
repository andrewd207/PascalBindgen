' demo_rqbasic.bas — spinning 3D cube driven by raylib via
' pascal_bindgen --rqbasic generated bindings. Stresses three
' things at once:
'
'   * SINGLE in records (Vector3 = 3 floats, Camera3D = nested)
'   * Struct-by-value FFI — every draw call takes Vector3/Color
'     by value, ABI-wise that's xmm0..1 / edi tag-classified slots
'   * Mixed const + record-value typing across the binding surface
'
' Camera looks down at the origin; cube spins via raylib's built-
' in DrawCubeWires + a manually-incremented Y rotation.

$INCLUDE "raylib_rqbasic.bas"

DIM cam AS Camera3D
DIM cube_pos AS Vector3
DIM cube_size AS Vector3
DIM bg AS Color
DIM fill AS Color
DIM wires AS Color

InitWindow(800, 600, PCHAR("raylib + rqbasic — spinning cube"))
SetTargetFPS(60)

cam.position.x = 4.0
cam.position.y = 4.0
cam.position.z = 4.0
cam.target.x = 0.0
cam.target.y = 0.0
cam.target.z = 0.0
cam.up.x = 0.0
cam.up.y = 1.0
cam.up.z = 0.0
cam.fovy = 45.0
cam.projection = 0   ' CAMERA_PERSPECTIVE

cube_pos.x = 0.0
cube_pos.y = 0.0
cube_pos.z = 0.0
cube_size.x = 2.0
cube_size.y = 2.0
cube_size.z = 2.0

bg.r    =  18: bg.g    =  18: bg.b    =  24: bg.a    = 255
fill.r  = 230: fill.g  =  90: fill.b  =  60: fill.a  = 255
wires.r = 255: wires.g = 255: wires.b = 255: wires.a = 255

WHILE WindowShouldClose() = 0
  UpdateCamera(VARPTR(cam), 3)   ' CAMERA_ORBITAL -- camera spins itself

  BeginDrawing()
    ClearBackground(bg)
    BeginMode3D(cam)
      DrawCubeV(cube_pos, cube_size, fill)
      DrawCubeWiresV(cube_pos, cube_size, wires)
      DrawGrid(10, 1.0)
    EndMode3D()
    DrawFPS(10, 10)
  EndDrawing()
WEND

CloseWindow()
