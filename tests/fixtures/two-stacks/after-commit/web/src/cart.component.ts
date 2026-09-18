export class CartComponent {
  total = 0;

  refresh(items: number[]) {
    this.total = items.reduce((a, b) => a + b, 0);
  }
}
