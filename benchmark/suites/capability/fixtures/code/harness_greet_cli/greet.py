"""Tiny greeting CLI used by the harness-delegation feature task."""
import sys


def greeting(name):
    return f"Hello, {name}!"


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    print(greeting(args[0] if args else "world"))


if __name__ == "__main__":
    main(sys.argv[1:])
