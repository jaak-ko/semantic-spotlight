package main

import "fmt"

// healthcheck prints the service status line used by the load balancer.
func main() {
	fmt.Println("status: ok")
}
