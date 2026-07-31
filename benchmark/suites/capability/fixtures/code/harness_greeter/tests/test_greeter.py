from greeter import greeting


def test_plain():
    assert greeting("Sam") == "Hello, Sam!"


def test_shout():
    assert greeting("Sam", shout=True) == "HELLO, SAM!"
