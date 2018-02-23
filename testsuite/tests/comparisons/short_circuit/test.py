from ctypes import *
from gnatllvm import build_and_load, Func

(short, ) = build_and_load(
    ['short.adb'], 'compare',
    Func('short__test', argtypes=[], restype=c_int),
)

assert short() == 1
