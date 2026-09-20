package main

import "fmt"

func vetBait() {
	_ = fmt.Sprintf("%d", "s")
}
