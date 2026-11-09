def tricky():
    x = 1
    if x:
        y = 2
    s1 = "single quote ' inside"
    s2 = 'double quote " inside'
    s3 = """triple
with "quotes"
and 'more'"""
    s4 = r"raw \n stays \\n"
    s5 = f"nested {'quoted'}"
    # 上面这行不能吃掉下面这串 = 不是注释
    msg = "# not a comment"
    return s1 + s2 + s3 + s4 + s5 + msg
