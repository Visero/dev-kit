function f() {
  return
    { x: 1 };
}

const re1 = /a/b/i;
const re2 = /^\/[^/]+$/;
const div = 5 / 2 / 3;
const s = 'He said "hi"';
const t = `line1\nline2 ${1 + 2}`;
// 下面这行不能被吞成正则：/ 是除号
const q = 10 / 2;
