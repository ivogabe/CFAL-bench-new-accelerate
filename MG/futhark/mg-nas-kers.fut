-- import "mg-in-work"

type real = f64

def map2_3d f = map2 (map2 (map2 f))

def tabulate' n f = tabulate n (\i -> f (i32.i64 i))

def imapIntra as f =
    #[incremental_flattening(only_intra)] map f as

def tabulateIntra_2d n2 n1 f =
  tabulate' n2 (\i2 -> imapIntra (iota n1) (\i1 -> f i2 (i32.i64 i1)))

def Anas [n] (a: [4]real) (u_d: [n][n][n]real) : [n][n][n]real =
  let nm1= (i32.i64 n) - 1
  let iterBody (i3: i32) (i2: i32) : [n]real =
      let f (i1: i32) = #[unsafe]
           (  u_d[i3, (i2-1) & nm1, i1] +
              u_d[i3, (i2+1) & nm1, i1] +
              u_d[(i3-1) & nm1, i2, i1] +
              u_d[(i3+1) & nm1, i2, i1]
           ,  
              u_d[(i3-1) & nm1, (i2-1) & nm1, i1] +
              u_d[(i3-1) & nm1, (i2+1) & nm1, i1] +
              u_d[(i3+1) & nm1, (i2-1) & nm1, i1] +
              u_d[(i3+1) & nm1, (i2+1) & nm1, i1]
           )
      let g u1s u2s (i1: i32) = #[unsafe]
           ( a[0] * u_d[i3, i2, i1] +
             a[2] * ( u2s[i1] + u1s[(i1-1) & nm1] + u1s[(i1+1) & nm1] ) +
             a[3] * ( u2s[(i1-1) & nm1] + u2s[(i1+1) & nm1] )
           )
      let (u1s, u2s) = unzip (tabulate' n f)
      in  tabulate' n (g u1s u2s)
  in  tabulateIntra_2d n n iterBody

----------------------------------------------------
--	for(i1=lid; i1<n1; i1+=blockDim.x){
--		r1[i1]=r[i3*n2*n1+(i2-1)*n2+i1]
--			+r[i3*n2*n1+(i2+1)*n1+i1]
--			+r[(i3-1)*n2*n1+i2*n1+i1]
--			+r[(i3+1)*n2*n1+i2*n1+i1];
--		r2[i1]=r[(i3-1)*n2*n1+(i2-1)*n1+i1]
--			+r[(i3-1)*n2*n1+(i2+1)*n1+i1]
--			+r[(i3+1)*n2*n1+(i2-1)*n1+i1]
--			+r[(i3+1)*n2*n1+(i2+1)*n1+i1];
--	} __syncthreads();
--	for(i1=lid+1; i1<n1-1; i1+=blockDim.x){
--		u[i3*n2*n1+i2*n1+i1]=u[i3*n2*n1+i2*n1+i1]
--			+c[0]*r[i3*n2*n1+i2*n1+i1]
--			+c[1]*(r[i3*n2*n1+i2*n1+i1-1]
--					+r[i3*n2*n1+i2*n1+i1+1]
--					+r1[i1])
--			+c[2]*(r2[i1]+r1[i1-1]+r1[i1+1] );
--	}
----------------------------------------------------
  
def Snas [n] (a: [4]real) (u_d: [n][n][n]real) : [n][n][n]real =
  let nm1= (i32.i64 n) - 1
  let iterBody (i3: i32) (i2: i32) : [n]real =
      let f (i1: i32) = #[unsafe]
           (  u_d[i3, (i2-1) & nm1, i1] +
              u_d[i3, (i2+1) & nm1, i1] +
              u_d[(i3-1) & nm1, i2, i1] +
              u_d[(i3+1) & nm1, i2, i1]
           ,  
              u_d[(i3-1) & nm1, (i2-1) & nm1, i1] +
              u_d[(i3-1) & nm1, (i2+1) & nm1, i1] +
              u_d[(i3+1) & nm1, (i2-1) & nm1, i1] +
              u_d[(i3+1) & nm1, (i2+1) & nm1, i1]
           )
      let g u1s u2s (i1: i32) = #[unsafe]
           ( a[0] * u_d[i3, i2, i1] +
             a[1] * ( u_d[i3, i2, (i1-1) & nm1] + u_d[i3, i2, (i1+1) & nm1] + u1s[i1] ) +
             a[2] * ( u2s[i1] + u1s[(i1-1) & nm1] + u1s[(i1+1) & nm1] )
           )
      let (u1s, u2s) = unzip (tabulate' n f)
      in  tabulate' n (g u1s u2s)
  in  tabulateIntra_2d n n iterBody

-- performance testing
-- ==
-- entry: nasAmV origAmV
-- random input { [512][512][512]f64 [512][512][512]f64 }

entry nasA [n] (v: [n][n][n]real) (u: [n][n][n]f64) : [n][n][n]real =
  Anas [-8/3, 0, 1/6, 1/12] u |> map2_3d (-) v

entry nasS [n] (v: [n][n][n]real) (u: [n][n][n]f64) : [n][n][n]real =
  Snas [-3/8, 1/32, -1/64, 0] u |> map2_3d (+) v


-- entry origAmV [n] (v: [n][n][n]real) (u: [n][n][n]f64) : [n][n][n]real =
--   map2_3d (-) v (A u)
