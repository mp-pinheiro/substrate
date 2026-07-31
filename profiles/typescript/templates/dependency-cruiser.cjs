/* Trimmed from `depcruise --init oneshot` (dependency-cruiser@18) to the two
   load-bearing rules. no-orphans stays warn: any standalone entry file is an
   orphan, so error severity would red every steady repo. gate:allow-comment */
/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    {
      name: 'no-circular',
      severity: 'error',
      comment:
        'This dependency is part of a circular relationship — break the cycle ' +
        '(dependency inversion, or merge the modules if they share one responsibility).',
      from: {},
      to: { circular: true }
    },
    {
      name: 'no-orphans',
      severity: 'warn',
      comment:
        "This is an orphan module — nothing imports it and it imports nothing. " +
        "Use it or remove it; add a pathNot exception here if it is intentional.",
      from: {
        orphan: true,
        pathNot: [
          '(^|/)[.][^/]+[.](?:js|cjs|mjs|ts|cts|mts|json)$',
          '[.]d[.]ts$',
          '(^|/)tsconfig[.]json$',
          '(^|/)(?:babel|webpack)[.]config[.](?:js|cjs|mjs|ts|cts|mts|json)$'
        ]
      },
      to: {}
    }
  ],
  options: {
    doNotFollow: { path: ['node_modules'] },
    enhancedResolveOptions: {
      exportsFields: ['exports'],
      conditionNames: ['import', 'require', 'node', 'default', 'types'],
      extensions: ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs']
    },
    skipAnalysisNotInRules: true
  }
};
