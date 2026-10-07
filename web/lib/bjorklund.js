// bjorklund — vendored from beats-bitwrap-io public/lib/generator/euclidean.js
// (the only symbol web/jog needs). Keep in step with upstream by hand.

export function bjorklund(k, n) {
    if (k >= n) {
        const result = new Array(n);
        for (let i = 0; i < n; i++) result[i] = 1;
        return result;
    }
    if (k === 0) {
        return new Array(n).fill(0);
    }

    // Build groups
    let groups = new Array(n);
    for (let i = 0; i < n; i++) {
        if (i < k) {
            groups[i] = [1];
        } else {
            groups[i] = [0];
        }
    }

    // Iteratively merge
    let kk = k;
    for (;;) {
        const remainder = groups.length - kk;
        if (remainder <= 1) break;

        let merges = kk;
        if (remainder < merges) merges = remainder;

        const newGroups = [];
        for (let i = 0; i < merges; i++) {
            newGroups.push(groups[i].concat(groups[groups.length - 1 - i]));
        }
        for (let i = merges; i < groups.length - merges; i++) {
            newGroups.push(groups[i]);
        }
        groups = newGroups;
        kk = merges;
        if (groups.length - kk <= 1) break;
    }

    // Flatten
    const result = [];
    for (const g of groups) {
        for (const v of g) result.push(v);
    }
    return result;
}
