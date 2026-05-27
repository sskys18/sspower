mod util;

use util::calc;

fn main() {
    let r = caller();
    println!("{}", r);
}

fn caller() -> i32 {
    calc(1, 2)
}

struct Worker;

impl Worker {
    fn run(&self) -> i32 {
        calc(3, 4)
    }
}
