module cloctree;
import globals;
/**
  In order to fit the octree on the GPU, I have to use a pool, so the
  data must be linear.
*/

/**
  Either the node of an octree or the octree itself. To get the voxel/children
  use an OctreeData, preferrably with the RNode and RVoxel functions. Note that
  the lack of an ID - the equivalence of a null - is -1.

  Also contains information on the origin of the node as well as half its size
    so to find its minimum X point, origin[0] - half_siz[0]
*/
struct CLOctreeNode {
  int[8] child_id;
  int voxel_id;
  float[3] origin;
  float[3] half_siz;
}

/**
  Contains BRDF, BTDF, size and position data
*/
struct CLVoxel {
  float[3] position;
  float    size;
}

/**
  Contains data of the nodes/voxels
*/
struct OctreeData {
  CLOctreeNode[] node_pool;
  CLVoxel[]      voxel_pool;
}

/**
  Returns a copy of the node
*/
CLOctreeNode RNode(inout OctreeData data, int node_id) {
  return *data.RNodePtr(node_id);
}

/**
  Returns a pointer to the node
*/
auto RNodePtr(inout OctreeData data, int node_id) in {
  assert(node_id >= 0 && node_id < data.node_pool.length,
         "node id out of range: " ~ node_id.to!string);
}   body   {
  return &data.node_pool[cast(size_t)node_id];
}

/**
  returns a copy of the voxel
*/
CLVoxel RVoxel(inout OctreeData data, int voxel_id) {
  return *data.RVoxelPtr(voxel_id);
}
/**
  returns a pointer to the voxel
*/
auto RVoxelPtr(inout OctreeData data, int voxel_id) in {
  assert(voxel_id >= 0 && voxel_id < data.voxel_pool.length,
         "voxel id out of range: " ~ voxel_id.to!string);
}   body   {
  return &data.voxel_pool[cast(size_t)voxel_id];
}

/**
  Constructs an octree from an origin and original dimensions (note its half
    of the preferred dimensions), requires you fill out the voxel data
    beforehand.
*/
auto Construct_CLOctree ( float[3] origin, float[3] half_siz,
                          inout CLVoxel[] data ) {
  OctreeData octree_data = {
    node_pool : [ Construct_Node(origin, half_siz) ],
    voxel_pool : data.dup
  };
  foreach ( i; 0 .. data.length ) octree_data.Insert(cast(int)i);
  return octree_data;
}

private CLOctreeNode Construct_Node (float[3] origin_, float[3] half_siz_) {
  CLOctreeNode node = {
    origin : origin_, half_siz : half_siz_,
    child_id : [-1, -1, -1, -1, -1, -1, -1, -1], voxel_id : -1
  };
  return node;
}

/**
  Returns the octant that the node lies in, more specifically, it returns
  the bitmask according to this diagram:
        ID : 0 1 2 3 4 5 6 7
  point > x: f f f f T T T T
  point > y: f f T T f f T T
  point > z: f T f T f T f T
*/
int ROctant_Mask ( inout CLOctreeNode node, inout float[3] point ) {
  int oct = 0;
  if ( node.origin[0] < point[0] ) oct |= 4;
  if ( node.origin[1] < point[1] ) oct |= 2;
  if ( node.origin[0] < point[0] ) oct |= 1;
  return oct;
}

/**
  Returns if the node is a leaf, that is, it has no children.
*/
bool Is_Leaf ( inout CLOctreeNode node ) {
  return node.child_id[0] == -1;
}

/**
  Inserts the node into the tree, given the voxel exists already
*/
void Insert ( ref OctreeData data, int voxel_id, int node_id = 0 ) in {
  assert(voxel_id >= 0 && voxel_id < data.voxel_pool.length,
         "voxel id out of range: " ~ voxel_id.to!string);
  assert(node_id >= 0 && node_id < data.node_pool.length,
         "node id out of range: " ~ node_id.to!string);
}   body   {
  auto node = &data.node_pool[cast(size_t)node_id];
  if ( (*node).Is_Leaf ) {
    if ( node.voxel_id == -1 ) {
      // if it's a leaf and the voxel ID is not set, we can set it for now
      node.voxel_id = voxel_id;
      return;
    } else {
      // Not enough room for two IDs, have to create a new set of octants
      // and insert the IDs into the octants
      int old_voxel_id = node.voxel_id;
      node.voxel_id = -1;
      int[8] child_id;

      foreach ( i; 0 .. 8 ) {
        import functional;
        auto new_origin = node.origin,
             new_dim    = node.half_siz.array.map!"a*0.5f".array.to!(float[3]);
        foreach ( p; 0 .. 3 )
          new_origin[p] += node.half_siz[p]* (i&(4/(1+p)) ? 0.5f : -0.5f);
        child_id[i] = cast(int)data.node_pool.length;
        data.node_pool ~= Construct_Node(new_origin, new_dim);
      }

      // I get some weird problem if I just use node.child_id[i] in
      // the above for loop; only the first element persists in the node pool
      node.child_id = child_id.dup;

      auto old_index = (*node).ROctant_Mask(data.RVoxel(old_voxel_id).position),
           new_index = (*node).ROctant_Mask(data.RVoxel(    voxel_id).position);
      Insert(data, old_voxel_id, node.child_id[old_index]);
      Insert(data,     voxel_id, node.child_id[new_index]);
    }
  } else {
    // Just recursively insert the node into the corresponding child
    // until we hit a leaf node
    auto index = (*node).ROctant_Mask(data.RVoxel(voxel_id).position);
    assert(node !is &data.node_pool[node.child_id[index]],
           "recursive node insertion - degenerate tree formed");
    Insert(data, voxel_id, node.child_id[index]);
  }
}


/**
  Counts the amount of nodes in the tree, mostly to check for degeneracy.
  It's much faster to just use data.node_pool.length
*/
int Count_Nodes ( inout OctreeData data, int node_id = 0 ) {
  auto node = data.RNode(node_id);
  if ( node.Is_Leaf ) {
    return cast(int)(node.voxel_id != -1);
  } else {
    int 서 = 0;
    foreach ( i; 0 .. 8 )
      서 += Count_Nodes(data, node.child_id[i]);
    return 서;
  }
}

/**
*/
void RBounds ( inout OctreeData data, int node_id,
               out float[3] min, out float[3] max ) {
  auto node = data.RNode(node_id);
  foreach ( i; 0 .. 3 ) {
    max[i] = node.origin[i] + node.half_siz[i];
    min[i] = node.origin[i] - node.half_siz[i];
  }
}

/**
  Returns as list of voxel ids for all voxels within the box
  described by min .. max
*/
int[] RVoxels_Inside_Box ( inout OctreeData data, float[3] min, float[3] max,
                           int node_id = 0) {
  auto node = data.RNode(node_id);
  if ( node.Is_Leaf ) {
    if ( node.voxel_id != -1 ) {
      float[3] p = data.RVoxel(node.voxel_id).position;
      if ( p[0] > max[0] || p[1] > max[1] || p[2] > max[2] ) return [];
      if ( p[0] < min[0] || p[1] < min[1] || p[2] < min[2] ) return [];
      return [ node.voxel_id ];
    }
    return [];
  } else {
    int[] results;
    foreach ( i; 0 .. 8 ) {
      float[3] cmax, cmin;
      RBounds(data, node_id, cmin, cmax);

      if ( cmax[0] < min[0] || cmax[1] < min[1] || cmax[2] < min[2]) continue;
      if ( cmin[0] > max[0] || cmin[1] > max[1] || cmin[2] > max[2]) continue;

      results ~= data.RVoxels_Inside_Box(min, max, node.child_id[i]);
    }
    return results;
  }
}

unittest {
  import std.stdio;
  float Rand() {
    import std.random;
    return uniform(-1.0f, 1.0f);
  }

  float[3] Rand_Vec() {
    return [Rand(), Rand(), Rand()];
  }

  bool Point_In_Box ( float[3] point, float[3] min, float[3] max ) {
    return point[0] >= min[0] && point[1] >= min[1] && point[2] >= min[2] &&
           point[0] <= max[0] && point[1] <= max[1] && point[2] <= max[2];
  }

  float[3][] points;
  stdout.flush();

  writeln("creating points ..");
  const size_t amt_points = 1_000_000;
  foreach ( i; 0 .. amt_points ) {
    points ~= Rand_Vec();
  }

  writeln("Creating voxels ..");
  CLVoxel[] voxels;
  {import functional; voxels = points.map!(n => CLVoxel(n)).array;}

  float[3] tree_origin = [0.0f, 0.0f, 0.0f],
           tree_half_siz = [1.0f, 1.0f, 1.0f];
  import functional;
  auto tree = Construct_CLOctree(tree_origin, tree_half_siz, voxels);
  // query box
  float[3] qmin = [-0.05f, -0.05f, -0.05f],
           qmax = [ 0.05f,  0.05f,  0.05f];

  // -- asserting insertion and bounds testing
  import std.datetime;
  {
    size_t Bruteforce_Test ( ) {
      int count;
      foreach ( i; 0 .. amt_points )
        count += cast(int)(Point_In_Box(points[i], qmin, qmax));
      return count;
    }

    size_t Octree_Test ( ) {
      return tree.RVoxels_Inside_Box(qmin, qmax).length;
    }

    auto result = benchmark!(Bruteforce_Test, Octree_Test)(25);
    auto bf_result = result[0].msecs,
         tt_result = result[1].msecs;
    writeln("Octree Unittest Results, ", amt_points, " points");
    writeln("Query box: ", qmin, " - ", qmax);
    writeln("Bruteforce time: ", bf_result, " milliseconds");
    writeln("Octree     time: ", tt_result, " milliseconds");
    assert(Bruteforce_Test == Octree_Test);
  }
}

struct Ray {
  float[3] origin, dir, invdir;
  int[3] sign;
}

auto Construct_Ray ( float[3] origin_, float[3] dir_ ) {
  import functional;
  Ray ray = {
    origin: origin_, dir: dir_,
    invdir: dir_.array.map!"1.0f/a".array.to!(float[3]),
    sign: dir_.array.map!"1.0f/a < 0".array.to!(int[3])
  };
}

// bool Ray_Intersection ( inout Voxel voxel, inout Ray ray ) {
//   return Ray_Intersection(
// }

bool Ray_Intersection ( float[3] min, float[3] max, inout Ray ray ) {
  return Ray_Intersection( [min, max], ray);
}
/**
  http://www.cs.utah.edu/~awilliam/box/box.pdf
*/
bool Ray_Intersection ( float[3][2] bounds, inout Ray ray ) {
  import functional, std.algorithm.mutation : swap;
  writeln("Checking: ", ray, " :: ", bounds);
  float tmin, tmax, ymin, ymax;
  tmin = (bounds[    ray.sign[0]][0] - ray.origin[0]) * ray.invdir[0];
  tmax = (bounds[1 - ray.sign[0]][0] - ray.origin[0]) * ray.invdir[0];
  ymin = (bounds[    ray.sign[1]][1] - ray.origin[1]) * ray.invdir[1];
  ymax = (bounds[1 - ray.sign[1]][1] - ray.origin[1]) * ray.invdir[1];
  if ( (tmin > ymax) || (ymin > tmax) ) return false;
  if ( ymin > tmin ) tmin = ymin;
  if ( tmax < tmax ) tmax = ymax;

  float zmin, zmax;
  zmin = (bounds[    ray.sign[2]][2] - ray.origin[2]) * ray.invdir[2];
  zmax = (bounds[1 - ray.sign[2]][2] - ray.origin[2]) * ray.invdir[2];

  if ( (tmin > zmax) || (zmin > tmax) ) return false;
  return true;
}

