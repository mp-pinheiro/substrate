export function pick(value: unknown): number {
    if (value === null || value === undefined) {
        throw new Error('value must be present');
    }
    return (value as any).count;
}
