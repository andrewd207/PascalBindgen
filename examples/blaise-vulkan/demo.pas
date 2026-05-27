{ Blaise port of the Vulkan loader-handshake demo.

  Same shape as examples/vulkan/demo.pas (FPC dialect) — creates a
  VkInstance, enumerates physical devices, prints one summary line
  per GPU, tears down. Built against the 13.6K-line vulkan_blaise.pas
  the generator produces under the --blaise flag.

  Demonstrates that the Blaise emitter's output is consumable by
  real Blaise code — not just parse/semantic-clean, but actually
  drives a system shared library through the generated externs. }
program demo;

uses
  sysutils, vulkan_blaise;

{ Wrap the SysV-x86_64 VK opaque-pointer handle types as Pointer-
  shaped variables so we don't have to fight Blaise's strict
  pointer-typing for the few cases below. }
function MakeVersion(major, minor, patch: Cardinal): Cardinal;
begin
  Result := (major shl 22) or (minor shl 12) or patch;
end;

function VersionMajor(v: Cardinal): Cardinal;
begin Result := (v shr 22) and $7F; end;

function VersionMinor(v: Cardinal): Cardinal;
begin Result := (v shr 12) and $3FF; end;

function VersionPatch(v: Cardinal): Cardinal;
begin Result := v and $FFF; end;

{ Tiny hex formatter — Blaise's sysutils has no IntToHex.
  String indexing in Blaise yields a Byte (not a Char), so we
  build the hex string via Copy on a NUL-less digits literal. }
function UIntToHex(n: Cardinal): string;
const
  digits = '0123456789ABCDEF';
var
  s: string;
  d: Integer;
begin
  if n = 0 then begin Result := '0'; Exit; end;
  s := '';
  while n > 0 do
  begin
    d := Integer(n and $F);
    s := Copy(digits, d + 1, 1) + s;
    n := n shr 4;
  end;
  Result := s;
end;

function VendorName(id: Cardinal): string;
begin
  if      id = $1002 then Result := 'AMD'
  else if id = $10DE then Result := 'NVIDIA'
  else if id = $8086 then Result := 'Intel'
  else if id = $13B5 then Result := 'ARM'
  else if id = $5143 then Result := 'Qualcomm'
  else if id = $10005 then Result := 'Mesa (software)'
  else Result := 'vendor 0x' + UIntToHex(id);
end;

function DeviceTypeName(t: Cardinal): string;
begin
  if      t = 0 then Result := 'other'
  else if t = 1 then Result := 'integrated GPU'
  else if t = 2 then Result := 'discrete GPU'
  else if t = 3 then Result := 'virtual GPU'
  else if t = 4 then Result := 'CPU'
  else Result := 'kind ' + IntToStr(Integer(t));
end;

procedure Die(const where: string; rc: Integer);
begin
  WriteLn(where + ' failed: VkResult=' + IntToStr(rc));
  Halt(1);
end;

var
  appInfo: VkApplicationInfo;
  createInfo: VkInstanceCreateInfo;
  instance: VkInstance;
  rc: VkResult;
  count: Cardinal;
  devices: array[0..15] of VkPhysicalDevice;   { fixed cap — most boxes have <=4 }
  props: VkPhysicalDeviceProperties;
  i: Integer;
  namePtr: PChar;
  name: string;
begin
  { Zero-init the application info struct. Blaise has no FillChar,
    so we touch each field explicitly. Anything not assigned here is
    zero by Blaise's default-init contract for record locals. }
  appInfo.sType := VK_STRUCTURE_TYPE_APPLICATION_INFO;
  appInfo.pNext := nil;
  appInfo.pApplicationName := PChar('pascal_bindgen blaise vulkan demo');
  appInfo.applicationVersion := MakeVersion(1, 0, 0);
  appInfo.pEngineName := PChar('pascal_bindgen');
  appInfo.engineVersion := MakeVersion(1, 0, 0);
  appInfo.apiVersion := MakeVersion(1, 0, 0);

  createInfo.sType := VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  createInfo.pNext := nil;
  createInfo.flags := 0;
  createInfo.pApplicationInfo := @appInfo;
  createInfo.enabledLayerCount := 0;
  createInfo.ppEnabledLayerNames := nil;
  createInfo.enabledExtensionCount := 0;
  createInfo.ppEnabledExtensionNames := nil;

  rc := vkCreateInstance(@createInfo, nil, @instance);
  if rc <> VK_SUCCESS then Die('vkCreateInstance', Integer(rc));
  WriteLn('VkInstance created');

  count := 0;
  rc := vkEnumeratePhysicalDevices(instance, @count, nil);
  if rc <> VK_SUCCESS then Die('vkEnumeratePhysicalDevices (count)', Integer(rc));
  WriteLn('found ' + IntToStr(Integer(count)) + ' physical device(s)');

  if count = 0 then
  begin
    vkDestroyInstance(instance, nil);
    Halt(0);
  end;
  if count > 16 then count := 16;

  rc := vkEnumeratePhysicalDevices(instance, @count, @devices[0]);
  if rc <> VK_SUCCESS then Die('vkEnumeratePhysicalDevices (data)', Integer(rc));

  for i := 0 to Integer(count) - 1 do
  begin
    vkGetPhysicalDeviceProperties(devices[i], @props);

    { props.deviceName is a fixed array[0..255] of Byte. Blaise won't
      let us index into a record-field-fixed-array directly, so we
      cast the field's address to PChar (NUL-terminated) and convert
      to a Blaise string. }
    namePtr := PChar(@props.deviceName);
    name := string(namePtr);

    WriteLn('  [' + IntToStr(i) + '] '
            + VendorName(props.vendorID) + ' — '
            + name + ' — Vulkan '
            + IntToStr(Integer(VersionMajor(props.apiVersion))) + '.'
            + IntToStr(Integer(VersionMinor(props.apiVersion))) + '.'
            + IntToStr(Integer(VersionPatch(props.apiVersion))) + ' — '
            + DeviceTypeName(Cardinal(props.deviceType)));
  end;

  vkDestroyInstance(instance, nil);
  WriteLn('clean shutdown');
end.
