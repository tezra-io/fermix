"""Tiny greeting CLI used by the harness-delegation capability task."""


def greeting(name, shout=False):
    message = f"Hello, {name}!"
    if shout:
        return name.upper()
    return message


if __name__ == "__main__":
    import sys

    args = [a for a in sys.argv[1:] if a != "--shout"]
    print(greeting(args[0] if args else "world", shout="--shout" in sys.argv))
