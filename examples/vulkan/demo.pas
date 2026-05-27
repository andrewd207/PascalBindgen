{ Small Vulkan demo against the generated bindings.

  Creates a VkInstance, enumerates the physical devices the loader
  knows about, queries VkPhysicalDeviceProperties for each, and
  prints a one-line summary (driver vendor, device name, Vulkan
  API version, device type). Tears down cleanly.

  The point is to prove the generator's 13.6K-line vulkan_fpc.pas
  is consumable: it exercises VK structs with sType+pNext chains,
  out-parameter count/data calls (vkEnumeratePhysicalDevices), an
  opaque-handle PVkInstance_T, a 256-byte char array nested in
  another struct, and several VK_* constants.

  No window, no surface, no queue work — just the loader handshake.
  Should run on any box with a working ICD. }
program demo;

{$mode objfpc}{$H+}

uses
  ctypes, SysUtils, vulkan_fpc;

const
  VK_MAX_PHYSICAL_DEVICE_NAME_SIZE = 256;

function MakeVersion(major, minor, patch: cuint): cuint; inline;
begin
  Result := (major shl 22) or (minor shl 12) or patch;
end;

function VersionMajor(v: cuint): cuint; inline;
begin Result := (v shr 22) and $7F; end;

function VersionMinor(v: cuint): cuint; inline;
begin Result := (v shr 12) and $3FF; end;

function VersionPatch(v: cuint): cuint; inline;
begin Result := v and $FFF; end;

function VendorName(id: cuint): string;
begin
  case id of
    $1002: Result := 'AMD';
    $10DE: Result := 'NVIDIA';
    $8086: Result := 'Intel';
    $13B5: Result := 'ARM';
    $5143: Result := 'Qualcomm';
    $1010: Result := 'ImgTec';
    $106B: Result := 'Apple';
    $10005: Result := 'Mesa (software)';
  else
    Result := Format('vendor 0x%x', [id]);
  end;
end;

function DeviceTypeName(t: VkPhysicalDeviceType): string;
begin
  case t of
    0: Result := 'other';
    1: Result := 'integrated GPU';
    2: Result := 'discrete GPU';
    3: Result := 'virtual GPU';
    4: Result := 'CPU';
  else
    Result := Format('kind %d', [t]);
  end;
end;

{ Convert the inline 256-char array field to a Pascal string. The
  C convention is NUL-terminated, so stop at the first zero byte. }
function NameToString(const arr: array of cchar): string;
var
  i: Integer;
begin
  Result := '';
  for i := Low(arr) to High(arr) do
  begin
    if arr[i] = 0 then Break;
    Result := Result + Chr(Byte(arr[i]));
  end;
end;

procedure Die(const where: string; rc: VkResult);
begin
  Writeln(StdErr, where, ' failed: VkResult=', rc);
  Halt(1);
end;

var
  appInfo: VkApplicationInfo;
  createInfo: VkInstanceCreateInfo;
  instance: VkInstance;
  rc: VkResult;
  count: cuint;
  devices: array of VkPhysicalDevice;
  props: VkPhysicalDeviceProperties;
  i: Integer;
begin
  FillChar(appInfo, SizeOf(appInfo), 0);
  appInfo.sType := VK_STRUCTURE_TYPE_APPLICATION_INFO;
  appInfo.pApplicationName := 'pascal_bindgen vulkan demo';
  appInfo.applicationVersion := MakeVersion(1, 0, 0);
  appInfo.pEngineName := 'pascal_bindgen';
  appInfo.engineVersion := MakeVersion(1, 0, 0);
  appInfo.apiVersion := MakeVersion(1, 0, 0);

  FillChar(createInfo, SizeOf(createInfo), 0);
  createInfo.sType := VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  createInfo.pApplicationInfo := @appInfo;

  rc := vkCreateInstance(@createInfo, nil, @instance);
  if rc <> VK_SUCCESS then Die('vkCreateInstance', rc);
  Writeln('VkInstance created');

  count := 0;
  rc := vkEnumeratePhysicalDevices(instance, @count, nil);
  if rc <> VK_SUCCESS then Die('vkEnumeratePhysicalDevices (count)', rc);
  Writeln('found ', count, ' physical device(s)');

  if count = 0 then
  begin
    vkDestroyInstance(instance, nil);
    Halt(0);
  end;

  SetLength(devices, count);
  rc := vkEnumeratePhysicalDevices(instance, @count, @devices[0]);
  if rc <> VK_SUCCESS then Die('vkEnumeratePhysicalDevices (data)', rc);

  for i := 0 to Integer(count) - 1 do
  begin
    FillChar(props, SizeOf(props), 0);
    vkGetPhysicalDeviceProperties(devices[i], @props);

    Writeln(Format('  [%d] %s — %s — Vulkan %d.%d.%d — %s',
      [i,
       VendorName(props.vendorID),
       NameToString(props.deviceName),
       VersionMajor(props.apiVersion),
       VersionMinor(props.apiVersion),
       VersionPatch(props.apiVersion),
       DeviceTypeName(props.deviceType)]));
  end;

  vkDestroyInstance(instance, nil);
  Writeln('clean shutdown');
end.
