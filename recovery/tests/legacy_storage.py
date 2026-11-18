"""Keep existing volume-level regression suites on the explicit legacy format."""


def legacy_args(args):
    args = list(args)
    if args and args[0] in ('create', 'create-selected', 'repair'):
        position = args.index('--') if '--' in args else len(args)
        args.insert(position, '--directory')
    return args
