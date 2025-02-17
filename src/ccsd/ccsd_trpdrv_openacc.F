      subroutine ccsd_trpdrv_openacc(t1,xeorb,
     &     g_objo,g_objv,g_coul,g_exch,
     &     ncor,nocc,nvir,iprt,emp4,emp5,
     &     oseg_lo,oseg_hi, kchunk)
      use iso_fortran_env
      use cudafor
      use cublas
      implicit none
!
#include "errquit.fh"
#include "global.fh"
#include "ccsd_len.fh"
#include "ccsdps.fh"
#include "util.fh"
#include "msgids.fh"
#include "yflop.fh"
!
      double precision, intent(inout) :: emp4,emp5
      double precision, intent(in) :: t1(*)
      double precision, intent(in) :: xeorb(*)
      integer, intent(in) :: ncor,nocc,nvir
      integer, intent(in) :: iprt
      integer, intent(in) :: g_objo,g_objv,g_coul,g_exch
      integer, intent(in) :: oseg_lo,oseg_hi, kchunk
      double precision, allocatable, device :: eorb(:)
      double precision, allocatable, device :: f1n(:,:)
      double precision, allocatable, device :: f2n(:,:)
      double precision, allocatable, device :: f3n(:,:)
      double precision, allocatable, device :: f4n(:,:)
      double precision, allocatable, device :: f1t(:,:)
      double precision, allocatable, device :: f2t(:,:)
      double precision, allocatable, device :: f3t(:,:)
      double precision, allocatable, device :: f4t(:,:)
      double precision, allocatable, managed :: Tij(:), Tkj(:)
      double precision, allocatable, managed :: Tia(:), Tka(:)
      double precision, allocatable, managed :: Xia(:), Xka(:)
      double precision, allocatable, managed :: Jia(:), Jka(:)
      double precision, allocatable, managed :: Jij(:), Jkj(:)
      double precision, allocatable, managed :: Kia(:), Kka(:)
      double precision, allocatable, managed :: Kij(:), Kkj(:)
      double precision, allocatable, managed :: Dja(:), Djka(:), Djia(:)
! used to make inline threaded tengy correct - for now
! it is correct that dint[cx]1 are paired with t1v2 and vice versa
! in the inlined tengy loops.  see ccsd_tengy in ccsd_trpdrv.F for
! verification of the i-k and k-i pairing of these.
      double precision, allocatable, managed :: dintc1(:),dintc2(:)
      double precision, allocatable, managed :: dintx1(:),dintx2(:)
      double precision, allocatable, managed :: t1v1(:),t1v2(:)
      integer :: alloc_error, err
!
      double precision :: emp4i,emp5i,emp4k,emp5k
      double precision :: eaijk,denom
      integer :: inode,next,nodes,me
      integer :: a,b,c,i,j,k,akold,av,nbf
      integer :: klo, khi
      integer nxtask
      external nxtask
      integer :: dgemm_flops, tengy_flops
      double precision agg_flops
!
!  Dependencies (global array, local array, handle):
!
!  These are waited on first
!
!      g_objv, Dja,  nbh_objv1
!      g_objv, Djka(1+(k-klo)*nvir), nbh_objv4(k)
!      g_objv, Djia, nbh_objv5
!
!  These are waited on later
!
!      g_objv, Tka,  nbh_objv2
!      g_objv, Xka,  nbh_objv3
!      g_objv, Tia,  nbh_objv6
!      g_objv, Xia,  nbh_objv7
!      g_objo, Tkj,  nbh_objo1
!      g_objo, Jkj,  nbh_objo2
!      g_objo, Kkj,  nbh_objo3
!      g_objo, Tij,  nbh_objo4
!      g_objo, Jij,  nbh_objo5
!      g_objo, Kij,  nbh_objo6
!      g_exch, Kka,  nbh_exch1
!      g_exch, Kia,  nbh_exch2
!      g_coul, Jka,  nbh_coul1
!      g_coul, Jia,  nbh_coul2
!
!  non-blocking handles
!
      integer nbh_objv1,nbh_objv2,nbh_objv3
      integer nbh_objv5,nbh_objv6,nbh_objv7
      integer nbh_objv4(nocc)
!
      integer nbh_objo1,nbh_objo2,nbh_objo3
      integer nbh_objo4,nbh_objo5,nbh_objo6
!
      integer nbh_exch1,nbh_exch2,nbh_coul1,nbh_coul2
      integer n_progr,pct_progr
      parameter(n_progr=20)
      logical i_progr(n_progr+1)
      ! timers
      double precision :: tt0, tt1, tc0, tc1
      integer(INT32) :: shi
      type(cublasHandle) :: handle(8)
      integer(kind=cuda_stream_kind) :: stream(8)
      integer(INT32) :: nv4, no4 ! cublasDgemm requires 32-bit integers
      integer(INT32), parameter :: cu_op_n = CUBLAS_OP_N
      integer(INT32), parameter :: cu_op_t = CUBLAS_OP_T
!
      nodes = ga_nnodes()
      me = ga_nodeid()
!
      if (me.eq.0) then
        write(6,99)
      endif
   99 format(2x,'Using Fortran OpenACC+CUBLAS in CCSD(T)')
      tt0 = util_wallsec()
      agg_flops = 0
      ! setup CUDA streams
      do shi=1,8
        err = cudaStreamCreate(stream(shi))
        if (err.ne.0) call errquit('cudaStreamCreate',err,UNKNOWN_ERR)
        err = cublasCreate(handle(shi))
        if (err.ne.0) call errquit('cublasCreate',err,UNKNOWN_ERR)
        err = cublasSetStream(handle(shi), stream(shi))
        if (err.ne.0) call errquit('cublasSetStream',err,UNKNOWN_ERR)
      end do
      tt1 = util_wallsec()
      if (me.eq.0) then
        write(6,500) tt1-tt0
  500   format('CU init took ',e15.5,' seconds')
      endif
!
! device-only temp arrays
! produced by DGEMM, consumed by TENGY
!
      allocate( f1n(1:nvir,1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f1n',1,MA_ERR)
      allocate( f2n(1:nvir,1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f2n',2,MA_ERR)
      allocate( f3n(1:nvir,1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f3n',3,MA_ERR)
      allocate( f4n(1:nvir,1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f4n',4,MA_ERR)
      allocate( f1t(1:nvir,1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f1t',5,MA_ERR)
      allocate( f2t(1:nvir,1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f2t',6,MA_ERR)
      allocate( f3t(1:nvir,1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f3t',7,MA_ERR)
      allocate( f4t(1:nvir,1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f4t',8,MA_ERR)
!
! device-only copy of input eorb
!
      nbf = ncor + nocc + nvir
      allocate( eorb(1:nbf), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('eorb',10,MA_ERR)
      eorb(1:nbf) = xeorb(1:nbf)
!
! for TENGY
!
      allocate( dintc1(1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('dintc1',11,MA_ERR)
      allocate( dintx1(1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('dintx1',12,MA_ERR)
      allocate( t1v1(1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('t1v1',13,MA_ERR)
      allocate( dintc2(1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('dintc2',14,MA_ERR)
      allocate( dintx2(1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('dintx2',15,MA_ERR)
      allocate( t1v2(1:nvir), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('t1v2',16,MA_ERR)
!
! UM arrays, produced by GA Get, consumed by DGEMM
!
      allocate( Tij(1:lnvv), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Tij',100,MA_ERR)
      allocate( Tkj(1:kchunk*lnvv), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Tkj',101,MA_ERR)
      allocate( Tia(1:lnov*nocc), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Tia',102,MA_ERR)
      allocate( Tka(1:kchunk*lnov), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Tka',103,MA_ERR)
      allocate( Xia(1:lnov*nocc), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Xia',104,MA_ERR)
      allocate( Xka(1:kchunk*lnov), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Xka',105,MA_ERR)
      allocate( Jia(1:lnvv), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Jia',106,MA_ERR)
      allocate( Jka(1:kchunk*lnvv), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Jka',107,MA_ERR)
      allocate( Kia(1:lnvv), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Kia',108,MA_ERR)
      allocate( Kka(1:kchunk*lnvv), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Kka',109,MA_ERR)
      allocate( Jij(1:lnov*nocc), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Jij',110,MA_ERR)
      allocate( Jkj(1:kchunk*lnov), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Jkj',111,MA_ERR)
      allocate( Kij(1:lnov*nocc), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Kij',112,MA_ERR)
      allocate( Kkj(1:kchunk*lnov), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Kkj',113,MA_ERR)
      allocate( Dja(1:lnov), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Dja',114,MA_ERR)
      allocate( Djka(1:nvir*kchunk), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Djka',115,MA_ERR)
      allocate( Djia(1:nvir*nocc), stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Djia',116,MA_ERR)
!
!      call ga_sync() ! ga_sync called just before trpdrv in aoccsd2
!
      if (occsdps) then
         call pstat_on(ps_trpdrv)
      else
         call qenter('trpdrv',0)
      endif
       do klo=1,n_progr+1
          i_progr(klo)=.true.
       enddo
      inode=-1
      next=nxtask(nodes, 1)
      do klo = 1, nocc, kchunk
         akold=0
         khi = min(nocc, klo+kchunk-1)
         do a=oseg_lo,oseg_hi
            av=a-ncor-nocc
            do j=1,nocc
               inode=inode+1
               if (inode.eq.next)then

                  call ga_nbget(g_objv,1+(j-1)*lnov,j*lnov,av,av,Dja,
     &                          lnov,nbh_objv1)
                  do k = klo, khi
                     call ga_nbget(g_objv,1+(j-1)*nvir+(k-1)*lnov,
     &                    j*nvir+(k-1)*lnov,av,av,
     &                    Djka(1+(k-klo)*nvir),nvir,nbh_objv4(k))
                  enddo
                  call ga_nbget(g_objo,(klo-1)*lnvv+1,khi*lnvv,j,j,Tkj,
     &                          (khi-klo+1)*lnvv,nbh_objo1)
                  call ga_nbget(g_objo,lnovv+(klo-1)*lnov+1,
     &                          lnovv+khi*lnov,j,j,Jkj,
     &                          (khi-klo+1)*lnov,nbh_objo2)
                  call ga_nbget(g_objo,lnovv+lnoov+(klo-1)*lnov+1,
     &                          lnovv+lnoov+khi*lnov,j,j,Kkj,
     &                          (khi-klo+1)*lnov,nbh_objo3)
                  if (akold .ne. a) then
                     akold = a
                     call ga_nbget(g_coul,1,lnvv,(a-oseg_lo)*nocc+klo,
     &                    (a-oseg_lo)*nocc+khi,Jka,lnvv,nbh_coul1)
                     call ga_nbget(g_exch,1,lnvv,(a-oseg_lo)*nocc+klo,
     &                    (a-oseg_lo)*nocc+khi,Kka,lnvv,nbh_exch1)
                     call ga_nbget(g_objv,1+lnoov+(klo-1)*lnov,
     &                    lnoov+khi*lnov,av,av,Tka,(khi-klo+1)*lnov,
     &                    nbh_objv2)
                     call ga_nbget(g_objv,1+2*lnoov+(klo-1)*lnov,
     &                    2*lnoov+khi*lnov,av,av,Xka,(khi-klo+1)*lnov,
     &                    nbh_objv3)
                  endif

                  do i=1,nocc

                     call ga_nbget(g_objv,1+(j-1)*nvir+(i-1)*lnov,
     &                    j*nvir+(i-1)*lnov,av,av,Djia,nvir,nbh_objv5)
                     call ga_nbget(g_objo,(i-1)*lnvv+1,i*lnvv,j,j,Tij,
     &                    lnvv,nbh_objo4)
                     call ga_nbget(g_objo,lnovv+(i-1)*lnov+1,
     &                    lnovv+i*lnov,j,j,Jij,lnov,nbh_objo5)
                     call ga_nbget(g_objo,lnovv+lnoov+(i-1)*lnov+1,
     &                    lnovv+lnoov+i*lnov,j,j,Kij,lnov,nbh_objo6)
                     call ga_nbget(g_coul,1,lnvv,(a-oseg_lo)*nocc+i,
     &                    (a-oseg_lo)*nocc+i,Jia,lnvv,nbh_coul2)
                     call ga_nbget(g_exch,1,lnvv,(a-oseg_lo)*nocc+i,
     &                    (a-oseg_lo)*nocc+i,Kia,lnvv,nbh_exch2)
                     call ga_nbget(g_objv,1+lnoov+(i-1)*lnov,
     &                    lnoov+i*lnov,av,av,Tia,lnov,nbh_objv6)
                     call ga_nbget(g_objv,1+2*lnoov+(i-1)*lnov,
     &                    2*lnoov+i*lnov,av,av,Xia,lnov,nbh_objv7)

!                     call dcopy(nvir,t1((i-1)*nvir+1),1,t1v2,1)
                     t1v2(:) = t1((i-1)*nvir+1:i*nvir)
                     call ga_nbwait(nbh_objv1) ! Dja
!                     call dcopy(nvir,Dja(1+(i-1)*nvir),1,dintc1,1)
                     dintc1(:) = Dja(1+(i-1)*nvir:i*nvir)
                     call ga_nbwait(nbh_objv5) ! Djia
!                     call dcopy(nvir,Djia,1,dintx1,1)
                     dintx1(:) = Djia(1:nvir)

                     do k=klo,min(khi,i)

                        !call dcopy(nvir,t1((k-1)*nvir+1),1,t1v1,1)
                        t1v1(:) = t1((k-1)*nvir+1:k*nvir)
                        !call dcopy(nvir,Dja(1+(k-1)*nvir),1,dintc2,1)
                        dintc2(:) = Dja(1+(k-1)*nvir:k*nvir)
                        call ga_nbwait(nbh_objv4(k)) ! Djka
                        !call dcopy(nvir,Djka(1+(k-klo)*nvir),1,dintx2,1)
                        dintx2(:) = Djka(1+(k-klo)*nvir:(k-klo+1)*nvir)
                        emp4i = 0.0d0
                        emp5i = 0.0d0
                        emp4k = 0.0d0
                        emp5k = 0.0d0
                        if (occsdps) then
                           call pstat_on(ps_doxxx)
                        else
                           call qenter('doxxx',0)
                        endif
!
!  These are the input dependencies for the DGEMM calls below.
!  We wait on all of them here because GA is not even remotely thread-safe.
!  All of these are independent of k, so we wait on them only
!  at the first trip of the loop.
!
                        if (k.eq.klo) then
                            call ga_nbwait(nbh_objv2)
                            call ga_nbwait(nbh_objv3)
                            call ga_nbwait(nbh_objv6)
                            call ga_nbwait(nbh_objv7)
                            call ga_nbwait(nbh_objo1)
                            call ga_nbwait(nbh_objo2)
                            call ga_nbwait(nbh_objo3)
                            call ga_nbwait(nbh_objo4)
                            call ga_nbwait(nbh_objo5)
                            call ga_nbwait(nbh_objo6)
                            call ga_nbwait(nbh_exch1)
                            call ga_nbwait(nbh_exch2)
                            call ga_nbwait(nbh_coul1)
                            call ga_nbwait(nbh_coul2)
                        endif

                        tc0 = util_wallsec()

                        nv4 = nvir ! no possibility of overflow
                        no4 = nocc

                        err = cublasDgemm_v2(handle(1),
     &                        cu_op_n,cu_op_t,
     &                        nv4,nv4,nv4,1.0d0,
     &                        Jia,nv4,Tkj(1+(k-klo)*lnvv),nv4,0.0d0,
     &                        f1n,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                        err = cublasDgemm_v2(handle(1),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,no4,-1.0d0,
     &                        Tia,nv4,Kkj(1+(k-klo)*lnov),no4,1.0d0,
     &                        f1n,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                       
                        err = cublasDgemm_v2(handle(2),
     &                        cu_op_n,cu_op_t,
     &                        nv4,nv4,nv4,1.0d0,
     &                        Kia,nv4,Tkj(1+(k-klo)*lnvv),nv4,0.0d0,
     &                        f2n,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                        err = cublasDgemm_v2(handle(2),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,no4,-1.0d0,
     &                        Xia,nv4,Kkj(1+(k-klo)*lnov),no4,1.0d0,
     &                        f2n,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                       
                        err = cublasDgemm_v2(handle(3),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,nv4,1.0d0,
     &                        Jia,nv4,Tkj(1+(k-klo)*lnvv),nv4,0.0d0,
     &                        f3n,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                        err = cublasDgemm_v2(handle(3),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,no4,-1.0d0,
     &                        Tia,nv4,Jkj(1+(k-klo)*lnov),no4,1.0d0,
     &                        f3n,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                       
                        err = cublasDgemm_v2(handle(4),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,nv4,1.0d0,
     &                        Kia,nv4,Tkj(1+(k-klo)*lnvv),nv4,0.0d0,
     &                        f4n,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                        err = cublasDgemm_v2(handle(4),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,no4,-1.0d0,
     &                        Xia,nv4,Jkj(1+(k-klo)*lnov),no4,1.0d0,
     &                        f4n,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                       
                        err = cublasDgemm_v2(handle(5),
     &                        cu_op_n,cu_op_t,
     &                        nv4,nv4,nv4,1.0d0,
     &                        Jka(1+(k-klo)*lnvv),nv4,Tij,nv4,0.0d0,
     &                        f1t,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                        err = cublasDgemm_v2(handle(5),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,no4,-1.0d0,
     &                        Tka(1+(k-klo)*lnov),nv4,Kij,no4,1.0d0,
     &                        f1t,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                       
                        err = cublasDgemm_v2(handle(6),
     &                        cu_op_n,cu_op_t,
     &                        nv4,nv4,nv4,1.0d0,
     &                        Kka(1+(k-klo)*lnvv),nv4,Tij,nv4,0.0d0,
     &                        f2t,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                        err = cublasDgemm_v2(handle(6),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,no4,-1.0d0,
     &                        Xka(1+(k-klo)*lnov),nv4,Kij,no4,1.0d0,
     &                        f2t,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                       
                        err = cublasDgemm_v2(handle(7),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,nv4,1.0d0,
     &                        Jka(1+(k-klo)*lnvv),nv4,Tij,nv4,0.0d0,
     &                        f3t,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                        err = cublasDgemm_v2(handle(7),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,no4,-1.0d0,
     &                        Tka(1+(k-klo)*lnov),nv4,Jij,no4,1.0d0,
     &                        f3t,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                       
                        err = cublasDgemm_v2(handle(8),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,nv4,1.0d0,
     &                        Kka(1+(k-klo)*lnvv),nv4,Tij,nv4,0.0d0,
     &                        f4t,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif
                        err = cublasDgemm_v2(handle(8),
     &                        cu_op_n,cu_op_n,
     &                        nv4,nv4,no4,-1.0d0,
     &                        Xka(1+(k-klo)*lnov),nv4,Jij,no4,1.0d0,
     &                        f4t,nv4)
                        if (err.ne.0) then
                          call errquit('cublasDgemm_v2',err,UNKNOWN_ERR)
                        endif

                        err = cudaDeviceSynchronize()
                        if (err.ne.0) then
                          call errquit('cudaDeviceSync',err,UNKNOWN_ERR)
                        endif

                        ! 8 pairs of DGEMM w/ VVV and VVO cost, 2 for FMA
                        dgemm_flops = 8*nvir*nvir*(nocc+nvir)*2
                        agg_flops = agg_flops + dgemm_flops

                        if (occsdps) then
                           call pstat_off(ps_doxxx)
                           call pstat_on(ps_tengy)
                        else
                           call qexit('doxxx',0)
                           call qenter('tengy',0)
                        endif

                        eaijk=eorb(a) - (  eorb(ncor+i)
     &                                    +eorb(ncor+j)
     &                                    +eorb(ncor+k) )
#ifdef USE_YFLOP
      flops_ycount = flops_ycount + nvir*nvir*(
     &                       3 + 2*(
     &                       12 +
     &                       11 +
     &                       11 ) +
     &                       2*27 )
#endif

!$acc parallel loop collapse(2) private(denom) 
!$acc&         reduction(+:emp4i,emp4k,emp5i,emp5k)
           do b=1,nvir
             do c=1,nvir
                   denom=-1.0d0/( eorb(ncor+nocc+b)
     &                           +eorb(ncor+nocc+c)+eaijk )
                   emp4i=emp4i+denom*
     &                  (f1t(b,c)+f1n(c,b)+f2t(c,b)+f3n(b,c)+f4n(c,b))*
     &                  (f1t(b,c)-2*f2t(b,c)-2*f3t(b,c)+f4t(b,c))
     &                        -denom*
     &                  (f1n(b,c)+f1t(c,b)+f2n(c,b)+f3n(c,b))*
     &                  (2*f1t(b,c)-f2t(b,c)-f3t(b,c)+2*f4t(b,c))
     &                        +3*denom*(
     &                  f1n(b,c)*(f1n(b,c)+f3n(c,b)+2*f4t(c,b))+
     &                  f2n(b,c)*f2t(c,b)+f3n(b,c)*f4t(b,c))
                   emp4k=emp4k+denom*
     &                  (f1n(b,c)+f1t(c,b)+f2n(c,b)+f3t(b,c)+f4t(c,b))*
     &                  (f1n(b,c)-2*f2n(b,c)-2*f3n(b,c)+f4n(b,c))
     &                        -denom*
     &                  (f1t(b,c)+f1n(c,b)+f2t(c,b)+f3t(c,b))*
     &                  (2*f1n(b,c)-f2n(b,c)-f3n(b,c)+2*f4n(b,c))
     &                        +3*denom*(
     &                  f1t(b,c)*(f1t(b,c)+f3t(c,b)+2*f4n(c,b))+
     &                  f2t(b,c)*f2n(c,b)+f3t(b,c)*f4n(b,c))
                   emp5i=emp5i+denom*t1v1(b)*dintx1(c)*
     &                 (    f1t(b,c)+f2n(b,c)+f4n(c,b)
     &                  -2*(f3t(b,c)+f4n(b,c)+f2n(c,b)+
     &                      f1n(b,c)+f2t(b,c)+f3n(c,b))
     &                  +4*(f3n(b,c)+f4t(b,c)+f1n(c,b)))
     &                        +denom*t1v1(b)*dintc1(c)*
     &                 (     f1n(b,c)+f4n(b,c)+f1t(c,b)
     &                   -2*(f2n(b,c)+f3n(b,c)+f2t(c,b)))
                   emp5k=emp5k+denom*t1v2(b)*dintx2(c)*
     &                 (    f1n(b,c)+f2t(b,c)+f4t(c,b)
     &                  -2*(f3n(b,c)+f4t(b,c)+f2t(c,b)+
     &                      f1t(b,c)+f2n(b,c)+f3t(c,b))
     &                  +4*(f3t(b,c)+f4n(b,c)+f1t(c,b)))
     &                        +denom*t1v2(b)*dintc2(c)*
     &                 (     f1t(b,c)+f4t(b,c)+f1n(c,b)
     &                   -2*(f2t(b,c)+f3t(b,c)+f2n(c,b)))
             end do
           end do
           tengy_flops = nvir*nvir*( 3 + 2*( 12 + 11 + 11 ) + 2*27 )
           agg_flops = agg_flops + tengy_flops

                         tc1 = util_wallsec()

                         if (occsdps) then
                            call pstat_off(ps_tengy)
                         else
                            call qexit('tengy',0)
                         endif

                         emp4 = emp4 + emp4i
                         emp5 = emp5 + emp5i
                         if (i.ne.k) then
                             emp4 = emp4 + emp4k
                             emp5 = emp5 + emp5k
                         end if ! (i.ne.k)
                     end do    ! k
                  end do       ! i
                  if (iprt.gt.50)then
                     write(6,1234)me,a,j,emp4,emp5
 1234                format(' me aijk',3i5,2e15.5)
                  end if
                  next=nxtask(nodes, 1)
            if(me.eq.0) then
               pct_progr=(a-(ncor+nocc)+((klo-1)/kchunk)*nvir)*n_progr/
     &                   ((nocc/kchunk)*nvir)+1
               if(i_progr(pct_progr)) then
                  i_progr(pct_progr)=.false.
               write(6,4321) ' ccsd(t): done ',
     &              a-(ncor+nocc)+((klo-1)/kchunk)*nvir,
     &              ' out of ',(nocc/kchunk)*nvir,
     &              ' progress: ',
     &              ((a-(ncor+nocc)+((klo-1)/kchunk)*nvir)*100)/
     &              ((nocc/kchunk)*nvir),
     &            '%, Gflops=',1e-9*(dgemm_flops+tengy_flops)/(tc1-tc0),
     &                 ' at ',(util_wallsec()-tt0),' secs'
               call util_flush(6)
 4321          format(a,i8,a,i8,a,i3,a,1pg11.4,a,0pf10.1,a)
               endif
            endif
               end if
            end do
         end do
      end do
      call ga_sync()
      next=nxtask(-nodes, 1)
      tt1=util_wallsec()
      call ga_dgop(msg_cc_diis1,agg_flops,1, '+')
      if(me.eq.0) then
         write(6,4322) ' ccsd(t): 100% done, Aggregate Gflops=',
     &        1e-9*agg_flops/(tt1-tt0),' in ',(tt1-tt0),' secs'
 4322    format(a,1pg11.4,a,0pf10.1,a)
         call util_flush(6)
      endif
      call ga_sync()
      if (occsdps) then
         call pstat_off(ps_trpdrv)
      else
         call qexit('trpdrv',0)
      endif
!
      deallocate( f1n, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f1n',1,MA_ERR)
      deallocate( f2n, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f2n',2,MA_ERR)
      deallocate( f3n, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f3n',3,MA_ERR)
      deallocate( f4n, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f4n',4,MA_ERR)
      deallocate( f1t, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f1t',5,MA_ERR)
      deallocate( f2t, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f2t',6,MA_ERR)
      deallocate( f3t, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f3t',7,MA_ERR)
      deallocate( f4t, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('f4t',8,MA_ERR)

      deallocate( eorb, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('eorb',10,MA_ERR)
      deallocate( dintc1, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('dintc1',11,MA_ERR)
      deallocate( dintx1, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('dintx1',12,MA_ERR)
      deallocate( t1v1, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('t1v1',13,MA_ERR)
      deallocate( dintc2, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('dintc2',14,MA_ERR)
      deallocate( dintx2, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('dintx2',15,MA_ERR)
      deallocate( t1v2, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('t1v2',16,MA_ERR)

      deallocate( Tij, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Tij',100,MA_ERR)
      deallocate( Tkj, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Tkj',101,MA_ERR)
      deallocate( Tia, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Tia',102,MA_ERR)
      deallocate( Tka, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Tka',103,MA_ERR)
      deallocate( Xia, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Xia',104,MA_ERR)
      deallocate( Xka, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Xka',105,MA_ERR)
      deallocate( Jia, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Jia',106,MA_ERR)
      deallocate( Jka, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Jka',107,MA_ERR)
      deallocate( Kia, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Kia',108,MA_ERR)
      deallocate( Kka, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Kka',109,MA_ERR)
      deallocate( Jij, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Jij',110,MA_ERR)
      deallocate( Jkj, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Jkj',111,MA_ERR)
      deallocate( Kij, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Kij',112,MA_ERR)
      deallocate( Kkj, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Kkj',113,MA_ERR)
      deallocate( Dja, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Dja',114,MA_ERR)
      deallocate( Djka, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Djka',115,MA_ERR)
      deallocate( Djia, stat=alloc_error)
      if (alloc_error.ne.0) call errquit('Djia',116,MA_ERR)
!
! CUDA stuff
!
      do shi=1,8
        err = cublasDestroy(handle(shi))
        if (err.ne.0) call errquit('cublasDestroy',err,UNKNOWN_ERR)
        err = cudaStreamDestroy(stream(shi))
        if (err.ne.0) call errquit('cudaStreamDestroy',err,UNKNOWN_ERR)
      end do
!
      end
