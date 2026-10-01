// SPDX-License-Identifier: MIT

// Command freeport prints a TCP port on 127.0.0.1 that was free a moment ago (the OS picks it by
// binding port 0). Scripts use it so that nothing in this project hard-codes a port.
package main

import (
	"fmt"
	"net"
	"os"
)

func main() {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, "freeport:", err)
		os.Exit(1)
	}
	fmt.Println(ln.Addr().(*net.TCPAddr).Port)
	_ = ln.Close()
}
