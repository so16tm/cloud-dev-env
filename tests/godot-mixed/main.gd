extends Node


func _ready() -> void:
	var greeter: Node = load("res://Greeter.cs").new()
	print("MIXED_OK: ", greeter.Greet("GDScript"))
	greeter.free()
	get_tree().quit()
