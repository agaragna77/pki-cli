# Authors:
#     Alessandro Garagnani <agaragna@redhat.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# Copyright (C) 2026 Alessandro Garagnani
#

"""Console entry for the pki-cli binary."""

from __future__ import annotations

import logging
import os
import subprocess
import sys

from pki.cli.main import PKICLI


def main(argv: list[str] | None = None) -> None:
    # Dogtag shell wrappers export these; keep the same defaults for a pip install.
    os.environ.setdefault('PKI_CLI_OPTIONS', '')
    os.environ.setdefault('NSS_DEFAULT_DB_TYPE', 'sql')

    logging.basicConfig(format='%(levelname)s: %(message)s')

    cli = PKICLI()
    try:
        cli.create_parser()
        cli.execute(sys.argv[1:] if argv is None else argv)
    except subprocess.CalledProcessError as e:
        if logging.getLogger().isEnabledFor(logging.DEBUG):
            logging.exception('Command: %s', ' '.join(e.cmd))
        elif logging.getLogger().isEnabledFor(logging.INFO):
            logging.error('Command: %s', ' '.join(e.cmd))
        sys.exit(e.returncode)
    except KeyboardInterrupt:
        print()
        sys.exit(-1)


if __name__ == '__main__':
    main()
