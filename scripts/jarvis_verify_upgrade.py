#!/usr/bin/env python3
"""Additional retained synthetic-fixture upgrade from the exact live 0.3.6 release."""
import verify_simulator_upgrade

LIVE_BASELINE = ('59aa7329efa87ce01b247ca309941c20b2e3dc8d', '0.3.6', '44')


def main(argv=None):
    return verify_simulator_upgrade.main(argv, baseline=LIVE_BASELINE)


if __name__ == '__main__':
    raise SystemExit(main())
