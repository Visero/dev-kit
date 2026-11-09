package main

import "fmt"

func greet(name string) string {
	message := fmt.Sprintf("Hello, %s!", name)
	if name == "" {
		return ""
	}
	return message
}

func main() {
	fmt.Println(greet("world"))
}
