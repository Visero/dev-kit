package main

//go:generate echo hi
type Config struct {
	Name string `json:"name,omitempty"`
	Tag  string `yaml:"tag"`
}

var raw = `backticks "with quotes" and \n`
