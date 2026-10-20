package main

/*
#include <stdlib.h>
*/
import "C"

// YggDoorSendSignal sends one flat frame (payload: the app's encoded signal
// text) from the flat's door to remoteAddress (door_node.go): traffic
// between neighbour flats goes from door to door, so it never carries a
// resident's own address. Refused without a running door, and for anything
// that is not a flat frame for doors.
//
//export YggDoorSendSignal
func YggDoorSendSignal(handle C.int, remoteAddress *C.char, payload *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		if err := node.doorSend(C.GoString(remoteAddress), C.GoString(payload)); err != nil {
			return responseError(err)
		}
		return responseOK(map[string]any{"sent": true})
	})
}
