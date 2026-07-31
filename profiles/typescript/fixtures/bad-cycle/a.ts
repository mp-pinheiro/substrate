import { b } from './b';

export function a(n: number): number {
    return n <= 0 ? 0 : b(n - 1);
}
