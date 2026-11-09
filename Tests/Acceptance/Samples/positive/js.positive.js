function greet(name) {
  const message = `Hello, ${name}!`;
  if (name.length === 0) {
    return;
  }
  console.log(message);
  return message;
}

const re = /ab+c/gi;
greet("world");
