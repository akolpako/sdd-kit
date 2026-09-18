package com.example;

public class CartTotals {
  public int sum(int[] lines) {
    int total = 0;
    for (int line : lines) {
      total += line;
    }
    return total;
  }
}
