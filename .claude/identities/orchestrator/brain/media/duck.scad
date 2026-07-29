// duck.scad — stylized duck for the neural-view SCAD preview
// (subset-friendly: spheres, cylinders, transforms, union only —
// renders in OpenSCAD too: F6, then File > Export as STL)
$fn = 48;
union() {
    // body
    translate([0, 0, 10]) scale([1.4, 1.0, 0.95]) sphere(10);
    // tail
    translate([-14, 0, 14]) rotate([0, -25, 0]) scale([0.8, 0.5, 0.45]) sphere(6);
    // head
    translate([11, 0, 22]) sphere(6.2);
    // beak
    translate([16, 0, 21]) rotate([0, 90, 0]) cylinder(6, 2.6, 0.9);
    // eyes
    translate([13.5, 3.6, 24]) sphere(0.9);
    translate([13.5, -3.6, 24]) sphere(0.9);
    // wings
    translate([0, 8.5, 12]) rotate([10, 0, 0]) scale([1.0, 0.35, 0.6]) sphere(7);
    translate([0, -8.5, 12]) rotate([-10, 0, 0]) scale([1.0, 0.35, 0.6]) sphere(7);
}
