import { a } from './a';

export function b(n: number): number {
    return n <= 0 ? 1 : a(n - 1) + 2;
}
