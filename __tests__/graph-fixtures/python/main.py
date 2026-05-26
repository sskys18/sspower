from helpers import helper
from pkg.util import calc

def caller():
    return helper(calc(1, 2))

class Worker:
    def run(self):
        return helper()
