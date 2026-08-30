import sys

lines = [line for line in sys.stdin.read().splitlines() if line]
operator = int(next(line.split("=", 1)[1] for line in lines if line.startswith("operator=")))
provided = int(next(line.split("=", 1)[1] for line in lines if line.startswith("provide_var=")))
record = next(line[4:] for line in lines if line.startswith("var="))
_, _, encoded = record.split(",", 2)
value = int(encoded.split(":", 1)[1])
ok = 1 if value == 8 else 0

sys.stdout.write(
    "STARLINGS/1 RESPONSE\n"
    f"operator={operator}\n"
    f"claim={provided},3,1000,{operator},b:{ok}\n"
    "END\n"
)
