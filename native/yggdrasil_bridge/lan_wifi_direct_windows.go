//go:build windows

package main

import (
	"errors"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The WLAN API's station interfaces and the IP helper's adapters, to tell
// a Wi-Fi Direct virtual adapter (isWifiDirectAdapter) by Go's interface
// name (the adapter's friendly name).
const (
	lanGaaSkipAnycast   = 0x2
	lanGaaSkipMulticast = 0x4
	lanGaaSkipDNSServer = 0x8
	// WLAN_INTERFACE_INFO_LIST: two DWORDs, then WLAN_INTERFACE_INFO items
	// (a GUID, WCHAR[256], an enum).
	lanWlanListHeader = 8
	lanWlanInfoSize   = 16 + 256*2 + 4
	lanWlanMaxItems   = 64
)

var (
	lanWlanAPI            = windows.NewLazySystemDLL("wlanapi.dll")
	lanWlanOpenHandle     = lanWlanAPI.NewProc("WlanOpenHandle")
	lanWlanCloseHandle    = lanWlanAPI.NewProc("WlanCloseHandle")
	lanWlanEnumInterfaces = lanWlanAPI.NewProc("WlanEnumInterfaces")
	lanWlanFreeMemory     = lanWlanAPI.NewProc("WlanFreeMemory")
)

func lanWifiDirectAdapter(name string) bool {
	stations := lanWlanStations()
	if len(stations) == 0 {
		return false
	}
	buffer, err := lanAdapters()
	if err != nil || len(buffer) == 0 {
		return false
	}
	for a := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buffer[0])); a != nil; a = a.Next {
		if windows.UTF16PtrToString(a.FriendlyName) == name {
			return isWifiDirectAdapter(a.IfType, windows.BytePtrToString(a.AdapterName), stations)
		}
	}
	return false
}

// lanWlanStations: the WLAN station interfaces ("{guid}", lower case); none
// without the WLAN service.
func lanWlanStations() map[string]bool {
	if lanWlanOpenHandle.Find() != nil {
		return nil
	}
	var version uint32
	var handle windows.Handle
	if r, _, _ := lanWlanOpenHandle.Call(2, 0, uintptr(unsafe.Pointer(&version)), uintptr(unsafe.Pointer(&handle))); r != 0 {
		return nil
	}
	defer lanWlanCloseHandle.Call(uintptr(handle), 0)
	var list unsafe.Pointer
	if r, _, _ := lanWlanEnumInterfaces.Call(uintptr(handle), 0, uintptr(unsafe.Pointer(&list))); r != 0 || list == nil {
		return nil
	}
	defer lanWlanFreeMemory.Call(uintptr(list))
	count := *(*uint32)(list)
	out := map[string]bool{}
	for i := 0; i < int(count) && i < lanWlanMaxItems; i++ {
		guid := (*windows.GUID)(unsafe.Add(list, lanWlanListHeader+i*lanWlanInfoSize))
		out[strings.ToLower(guid.String())] = true
	}
	return out
}

// lanAdapters: GetAdaptersAddresses' list (as Go's net package reads it).
func lanAdapters() ([]byte, error) {
	size := uint32(15000)
	for attempt := 0; attempt < 4; attempt++ {
		buffer := make([]byte, size)
		err := windows.GetAdaptersAddresses(syscall.AF_UNSPEC,
			lanGaaSkipAnycast|lanGaaSkipMulticast|lanGaaSkipDNSServer, 0,
			(*windows.IpAdapterAddresses)(unsafe.Pointer(&buffer[0])), &size)
		if err == nil {
			if size == 0 {
				return nil, nil
			}
			return buffer, nil
		}
		if !errors.Is(err, windows.ERROR_BUFFER_OVERFLOW) || size <= uint32(len(buffer)) {
			return nil, err
		}
	}
	return nil, windows.ERROR_BUFFER_OVERFLOW
}
