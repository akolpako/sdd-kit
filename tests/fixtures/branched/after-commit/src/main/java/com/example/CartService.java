package com.example;

public class CartService {
  public int total(int count, int price) {
    return count * price - discount(count);
  }

  private int discount(int count) {
    return count > 10 ? 5 : 0;
  }
}
