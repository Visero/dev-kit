#include <string>
#include <vector>
#include <iostream>

std::string greet(const std::string &name) {
    return "Hello, " + name + "!";
}

int main() {
    std::vector<std::string> names = {"a", "b"};
    for (const auto &n : names) {
        std::cout << greet(n) << std::endl;
    }
    return 0;
}
