import yaml
fname = "data.yaml"

dct = {"Jan": {"score": 3, "city": "Karvina"}, "David": {"score": 33, "city": "Brno"}}

with open(fname, "w") as f:
    yaml.dump(dct, f)

with open(fname) as f:
    newdct = yaml.load(f)

print newdct
newdct["Pipi"]["city"] = {"phonenumber": {cell: 99}}

x = newdct["Pipi"]

print(x)
# newdct["spec"] = {"sha256": 320, "id": "woot"}

with open(fname, "w") as f:
    yaml.dump(newdct, f)