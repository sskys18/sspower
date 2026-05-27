package main

import (
  "fixture/sample/util"
)

func main() {
  result := util.Calc(1, 2)
  println(result)
}

type Worker struct{}

func (w *Worker) Run() int {
  return util.Calc(3, 4)
}
