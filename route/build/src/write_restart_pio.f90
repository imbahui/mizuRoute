MODULE write_restart_pio

! Moudle wide shared data/external routines
USE nrtype

USE var_lookup,        ONLY: ixStateDims, nStateDims
USE var_lookup,        ONLY: ixIRFbas, nVarsIRFbas
USE var_lookup,        ONLY: ixIRF, nVarsIRF
USE var_lookup,        ONLY: ixKWT, nVarsKWT
USE var_lookup,        ONLY: ixKW, nVarsKW
USE var_lookup,        ONLY: ixMC, nVarsMC
USE var_lookup,        ONLY: ixDW, nVarsDW
USE var_lookup,        ONLY: ixIRFbas, nVarsIRFbas
USE var_lookup,        ONLY: ixBasinQ, nVarsBasinQ

USE dataTypes,         ONLY: STRFLX            ! fluxes in each reach
USE dataTypes,         ONLY: STRSTA            ! state in each reach
USE dataTypes,         ONLY: RCHTOPO           ! Network topology
USE dataTypes,         ONLY: states
USE datetime_data,     ONLY: datetime

USE public_var,        ONLY: iulog             ! i/o logical unit number
USE public_var,        ONLY: integerMissing
USE public_var,        ONLY: realMissing
USE public_var,        ONLY: verySmall

USE globalData,        ONLY: meta_stateDims  ! states dimension meta
USE globalData,        ONLY: meta_irf_bas
USE globalData,        ONLY: meta_basinQ
USE globalData,        ONLY: meta_irf
USE globalData,        ONLY: meta_kwt
USE globalData,        ONLY: meta_kw
USE globalData,        ONLY: meta_mc
USE globalData,        ONLY: meta_dw

USE globalData,        ONLY: pid, nNodes
USE globalData,        ONLY: masterproc
USE globalData,        ONLY: mpicom_route
USE globalData,        ONLY: pio_netcdf_format
USE globalData,        ONLY: pio_typename
USE globalData,        ONLY: pio_numiotasks
USE globalData,        ONLY: pio_rearranger
USE globalData,        ONLY: pio_root
USE globalData,        ONLY: pio_stride
USE globalData,        ONLY: pioSystem
USE globalData,        ONLY: runMode
USE globalData,        ONLY: rfileout

USE nr_utils,          ONLY: arth
USE pio_utils

implicit none

! The following variables used only in this module
type(file_desc_t)    :: pioFileDescState     ! contains data identifying the file
type(io_desc_t)      :: iodesc_state_int
type(io_desc_t)      :: iodesc_state_double
type(io_desc_t)      :: iodesc_wave_int
type(io_desc_t)      :: iodesc_wave_double
type(io_desc_t)      :: iodesc_mesh_kw_double
type(io_desc_t)      :: iodesc_mesh_mc_double
type(io_desc_t)      :: iodesc_mesh_dw_double
type(io_desc_t)      :: iodesc_irf_double
type(io_desc_t)      :: iodesc_vol_double
type(io_desc_t)      :: iodesc_irf_bas_double

integer(i4b),    parameter :: currTimeStep = 1
integer(i4b),    parameter :: nextTimeStep = 2

private

public::restart_fname
public::restart_output
public::main_restart     ! used for stand-alone

CONTAINS

 ! *********************************************************************
 ! public subroutine: restart write main routine
 ! *********************************************************************
 SUBROUTINE main_restart(ierr, message)

  implicit none
  ! output variables
  integer(i4b),   intent(out)          :: ierr             ! error code
  character(*),   intent(out)          :: message          ! error message
  ! local variables
  logical(lgt)                         :: restartAlarm     ! logical to make alarm for restart writing
  character(len=strLen)                :: cmessage         ! error message of downwind routine

  ierr=0; message='main_restart/'

  call restart_alarm(restartAlarm, ierr, cmessage)
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

  if (restartAlarm) then
    call restart_output(ierr, cmessage)
    if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
  end if

 END SUBROUTINE main_restart


 ! *********************************************************************
 ! private subroutine: restart alarming
 ! *********************************************************************
 SUBROUTINE restart_alarm(restartAlarm, ierr, message)

   USE ascii_utils, ONLY: lower
   USE public_var,        ONLY: calendar
   USE public_var,        ONLY: restart_write  ! restart write options
   USE public_var,        ONLY: restart_day
   USE globalData,        ONLY: restDatetime   ! restart Calendar time
   USE globalData,        ONLY: dropDatetime   ! restart drop off Calendar time
   USE globalData,        ONLY: simDatetime    ! previous and current model time

   implicit none

   ! output
   logical(lgt),   intent(out)          :: restartAlarm     ! logical to make alarm for restart writing
   integer(i4b),   intent(out)          :: ierr             ! error code
   character(*),   intent(out)          :: message          ! error message
   ! local variables
   character(len=strLen)                :: cmessage         ! error message of downwind routine
   integer(i4b)                         :: nDays            ! number of days in a month

   ierr=0; message='restart_alarm/'

   ! adjust restart dropoff day if the dropoff day is outside number of days in particular month
   dropDatetime = datetime(dropDatetime%year(), dropDatetime%month(), restart_day, dropDatetime%hour(), dropDatetime%minute(), dropDatetime%sec())

   nDays = simDatetime(1)%ndays_month(calendar, ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

   if (dropDatetime%day() > nDays) then
     dropDatetime = datetime(dropDatetime%year(), dropDatetime%month(), nDays, dropDatetime%hour(), dropDatetime%minute(), dropDatetime%sec())
   end if

   ! adjust dropoff day further if restart day is actually outside number of days in a particular month
   if (restDatetime%day() > nDays) then
     dropDatetime = dropDatetime%add_day(-1, calendar, ierr, cmessage)
     if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
   end if

   select case(lower(trim(restart_write)))
     case('specified','last')
       restartAlarm = (dropDatetime==simDatetime(1))
     case('yearly')
       restartAlarm = (dropDatetime%is_equal_mon(simDatetime(1)) .and. dropDatetime%is_equal_day(simDatetime(1)) .and. dropDatetime%is_equal_time(simDatetime(1)))
     case('monthly')
       restartAlarm = (dropDatetime%is_equal_day(simDatetime(1)) .and. dropDatetime%is_equal_time(simDatetime(1)))
     case('daily')
       restartAlarm = dropDatetime%is_equal_time(simDatetime(1))
     case('never')
       restartAlarm = .false.
     case default
       ierr=20; message=trim(message)//'Accepted <restart_write> options (case insensitive): last, never, specified, yearly, monthly, or daily '; return
   end select

 END SUBROUTINE restart_alarm


 ! *********************************************************************
 ! Public subroutine: output restart netcdf
 ! *********************************************************************
 SUBROUTINE restart_output(ierr, message)

  USE io_rpointfile, ONLY: io_rpfile

  implicit none
  ! output variables
  integer(i4b),   intent(out)          :: ierr             ! error code
  character(*),   intent(out)          :: message          ! error message
  ! local variables
  character(len=strLen)                :: cmessage         ! error message of downwind routine

  ierr=0; message='restart_output/'

  call restart_fname(rfileout, nextTimeStep, ierr, cmessage)
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

  call define_state_nc(rfileout, ierr, cmessage)
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

  call write_state_nc(rfileout, ierr, cmessage)
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

  call io_rpfile('w', ierr, cmessage)
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 END SUBROUTINE restart_output


 ! *********************************************************************
 ! public subroutine: define restart NetCDF file name
 ! *********************************************************************
 SUBROUTINE restart_fname(fname, timeStamp, ierr, message)

   USE public_var, ONLY: restart_dir
   USE public_var, ONLY: case_name      ! simulation name ==> output filename head
   USE public_var, ONLY: calendar
   USE public_var, ONLY: secprday
   USE public_var, ONLY: dt
   USE globalData, ONLY: simDatetime    ! current model datetime

   implicit none

   ! input
   integer(i4b),   intent(in)           :: timeStamp        ! optional:
   ! output
   character(*),   intent(out)          :: fname            ! name of the restart file name
   integer(i4b),   intent(out)          :: ierr             ! error code
   character(*),   intent(out)          :: message          ! error message
   ! local variables
   type(datetime)                       :: restartTimeStamp ! datetime corresponding to file name time stamp
   character(len=strLen)                :: cmessage         ! error message of downwind routine
   integer(i4b)                         :: sec_in_day       ! second within day
   character(len=50),parameter          :: fmtYMDHMS = '(2a,I0.4,a,I0.2,a,I0.2,x,I0.2,a,I0.2,a,I0.2)'
   character(len=50),parameter          :: fmtYMDS='(a,I0.4,a,I0.2,a,I0.2,a,I0.5,a)'

   ierr=0; message='restart_fname/'

   select case(timeStamp)
     case(currTimeStep); restartTimeStamp = simDatetime(1)
     case(nextTimeStep); restartTimeStamp = simDatetime(1)%add_sec(dt, calendar, ierr, cmessage)
     case default;       ierr=20; message=trim(message)//'time stamp option in restart filename: invalid -> 1: current time Step or 2: next time step'; return
   end select

  if (masterproc) then
    write(iulog,fmtYMDHMS) new_line('a'),'Write restart file for ', &
                           restartTimeStamp%year(),'-',restartTimeStamp%month(), '-', restartTimeStamp%day(), &
                           restartTimeStamp%hour(),':',restartTimeStamp%minute(),':',nint(restartTimeStamp%sec())
  end if

   sec_in_day = restartTimeStamp%hour()*60*60+restartTimeStamp%minute()*60+nint(restartTimeStamp%sec())

   select case(trim(runMode))
     case('cesm-coupling')
       write(fname, fmtYMDS) trim(restart_dir)//trim(case_name)//'.mizuroute.r.', &
                                  restartTimeStamp%year(),'-',restartTimeStamp%month(),'-',restartTimeStamp%day(),'-',sec_in_day,'.nc'
     case('standalone')
       write(fname, fmtYMDS) trim(restart_dir)//trim(case_name)//'.r.', &
                                  restartTimeStamp%year(),'-',restartTimeStamp%month(),'-',restartTimeStamp%day(),'-',sec_in_day,'.nc'
     case default; ierr=20; message=trim(message)//'unable to identify the run option. Avaliable options are standalone and cesm-coupling'; return
   end select

 END SUBROUTINE restart_fname


 ! *********************************************************************
 ! subroutine: define restart NetCDF file
 ! *********************************************************************
 SUBROUTINE define_state_nc(fname,           &  ! input: filename
                            ierr, message)      ! output: error control

 USE public_var, ONLY: time_units               ! time units (seconds, hours, or days)
 USE public_var, ONLY: calendar                 ! calendar name
 USE public_var, ONLY: doesBasinRoute
 USE public_var, ONLY: impulseResponseFunc
 USE public_var, ONLY: kinematicWaveTracking
 USE public_var, ONLY: kinematicWave
 USE public_var, ONLY: muskingumCunge
 USE public_var, ONLY: diffusiveWave
 USE globalData, ONLY: onRoute                  ! logical to indicate which routing method(s) is on
 USE globalData, ONLY: rch_per_proc             ! number of reaches assigned to each proc (size = num of procs+1)
 USE globalData, ONLY: nRch                     ! number of ensembles and river reaches

 implicit none
 ! argument variables
 character(*),   intent(in)      :: fname            ! filename
 integer(i4b),   intent(out)     :: ierr             ! error code
 character(*),   intent(out)     :: message          ! error message
 ! local variables
 integer(i4b)                    :: ix1, ix2         ! frst and last indices of global array for local array chunk
 integer(i4b)                    :: ixRch(nRch)      ! global reach index used for output
 integer(i4b)                    :: jDim             ! loop index for dimension
 integer(i4b)                    :: ixDim_common(3)  ! custom dimension ID array
 character(len=strLen)           :: cmessage         ! error message of downwind routine

 ! Initialize error control
 ierr=0; message='define_state_nc/'

 associate(dim_seg     => meta_stateDims(ixStateDims%seg)%dimId,     &
           dim_ens     => meta_stateDims(ixStateDims%ens)%dimId,     &
           dim_tbound  => meta_stateDims(ixStateDims%tbound)%dimId)

 ! ----------------------------------
 ! pio initialization for restart netCDF
 ! ----------------------------------
 if (trim(runMode)=='standalone') then
   pio_numiotasks = nNodes/pio_stride
   call pio_sys_init(pid, mpicom_route,          & ! input: MPI related parameters
                     pio_stride, pio_numiotasks, & ! input: PIO related parameters
                     pio_rearranger, pio_root,   & ! input: PIO related parameters
                     pioSystem)                    ! output: PIO system descriptors
 end if

 ! ----------------------------------
 ! Create file
 ! ----------------------------------
 call createFile(pioSystem, trim(fname), pio_typename, pio_netcdf_format, pioFileDescState, ierr, cmessage)
 if(ierr/=0)then; message=trim(cmessage)//'cannot create state netCDF'; return; endif

 ! For common dimension/variables - seg id, time, time-bound -----------
 ixDim_common = [ixStateDims%seg, ixStateDims%ens, ixStateDims%tbound]

 ! ----------------------------------
 ! Define dimensions
 ! ----------------------------------
 do jDim = 1,size(ixDim_common)
  associate(ixDim => ixDim_common(jDim))
  if (meta_stateDims(ixDim)%dimLength == integerMissing) then
   call set_dim_len(ixDim, ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage)//' for '//trim(meta_stateDims(ixDim)%dimName); return; endif
  endif
  call def_dim(pioFileDescState, trim(meta_stateDims(ixDim)%dimName), meta_stateDims(ixDim)%dimLength, meta_stateDims(ixDim)%dimId)
  end associate
 end do

 ! ----------------------------------
 ! Define variable
 ! ----------------------------------
 call def_var(pioFileDescState, 'nNodes', ncd_int, ierr, cmessage, vdesc='Number of MPI tasks',  vunit='-' )
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 call def_var(pioFileDescState, 'reachID', ncd_int, ierr, cmessage, pioDimId=[dim_seg], vdesc='reach ID',  vunit='-' )
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 call def_var(pioFileDescState, 'restart_time', ncd_float, ierr, cmessage, vdesc='resatart time', vunit=trim(time_units), vcal=calendar)
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 call def_var(pioFileDescState, 'time_bound', ncd_float, ierr, cmessage, pioDimId=[dim_tbound], vdesc='time bound at last time step', vunit='sec')
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 end associate

 ! previous-time step hru inflow into reach
 call define_basinQ_state(ierr, cmessage)
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 ! Routing specific variables --------------
 ! basin IRF
 if (doesBasinRoute==1) then
   call define_IRFbas_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 if (onRoute(impulseResponseFunc))then
   call define_IRF_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 if (onRoute(kinematicWaveTracking)) then
   call define_KWT_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 if (onRoute(kinematicWave)) then
   call define_KW_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 if (onRoute(muskingumCunge)) then
   call define_MC_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 if (onRoute(diffusiveWave)) then
   call define_DW_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 ! ----------------------------------
 ! pio initialization of decomposition
 ! ----------------------------------
 associate(nSeg     => meta_stateDims(ixStateDims%seg)%dimLength,     &
           nEns     => meta_stateDims(ixStateDims%ens)%dimLength,     &
           ntdh     => meta_stateDims(ixStateDims%tdh)%dimLength,     & ! maximum future q time steps among basins
           ntdh_irf => meta_stateDims(ixStateDims%tdh_irf)%dimLength, & ! maximum future q time steps among reaches
           nTbound  => meta_stateDims(ixStateDims%tbound)%dimLength,  & ! time bound
           nMesh_kw => meta_stateDims(ixStateDims%mol_kw)%dimLength,  & ! kw_finite difference mesh points
           nMesh_mc => meta_stateDims(ixStateDims%mol_mc)%dimLength,  & ! mc_finite difference mesh points
           nMesh_dw => meta_stateDims(ixStateDims%mol_dw)%dimLength,  & ! dw_finite difference mesh points
           nWave    => meta_stateDims(ixStateDims%wave)%dimLength)      ! maximum waves allowed in a reach

 if (masterproc) then
   ix1 = 1
 else
   ix1 = sum(rch_per_proc(-1:pid-1))+1
 endif
 ix2 = sum(rch_per_proc(-1:pid))
 ixRch = arth(1,1,nSeg)

 ! type: float  dim: [dim_seg, dim_ens]  -- channel runoff coming from hru
 call pio_decomp(pioSystem,              & ! input: pio system descriptor
                 ncd_double,             & ! input: data type (pio_int, pio_real, pio_double, pio_char)
                 [nSeg,nEns],            & ! input: dimension length == global array size
                 ixRch(ix1:ix2),         & ! input:
                 iodesc_state_double)

 ! type: int  dim: [dim_seg, dim_ens]  -- number of wave or uh future time steps
 call pio_decomp(pioSystem,              & ! input: pio system descriptor
                 ncd_int,                & ! input: data type (pio_int, pio_real, pio_double, pio_char)
                 [nSeg,nEns],            & ! input: dimension length == global array size
                 ixRch(ix1:ix2),         & ! input:
                 iodesc_state_int)

 if (doesBasinRoute==1) then
   ! type: float dim: [dim_seg, dim_tdh_irf, dim_ens]
   call pio_decomp(pioSystem,              & ! input: pio system descriptor
                   ncd_double,             & ! input: data type (pio_int, pio_real, pio_double, pio_char)
                   [nSeg,ntdh,nEns],       & ! input: dimension length == global array size
                   ixRch(ix1:ix2),         & ! input:
                   iodesc_irf_bas_double)
 end if

 if (onRoute(impulseResponseFunc))then
   ! type: float dim: [dim_seg, dim_tdh_irf, dim_ens]
   call pio_decomp(pioSystem,              & ! input: pio system descriptor
                   ncd_double,             & ! input: data type (pio_int, pio_real, pio_double, pio_char)
                   [nSeg,ntdh_irf,nEns],   & ! input: dimension length == global array size
                   ixRch(ix1:ix2),         & ! input:
                   iodesc_irf_double)

   ! type: float dim: [dim_seg, dim_ens]
   call pio_decomp(pioSystem,              & ! input: pio system descriptor
                   ncd_double,             & ! input: data type (pio_int, pio_real, pio_double, pio_char)
                   [nSeg,nTbound,nEns],    & ! input: dimension length == global array size
                   ixRch(ix1:ix2),         & ! input:
                   iodesc_vol_double)
 end if

 if (onRoute(kinematicWaveTracking)) then
   ! type: int, dim: [dim_seg, dim_wave, dim_ens]
   call pio_decomp(pioSystem,              & ! input: pio system descriptor
                   ncd_int,                & ! input: data type (pio_int, pio_real, pio_double, pio_char)
                   [nSeg,nWave,nEns],      & ! input: dimension length == global array size
                   ixRch(ix1:ix2),         & ! input:
                   iodesc_wave_int)

   ! type: float, dim: [dim_seg, dim_wave, dim_ens]
   call pio_decomp(pioSystem,              & ! input: pio system descriptor
                   ncd_double,             & ! input: data type (pio_int, pio_real, pio_double, pio_char)
                   [nSeg,nWave,nEns],      & ! input: dimension length == global array size
                   ixRch(ix1:ix2),         & ! input:
                   iodesc_wave_double)
 end if

 if (onRoute(kinematicWave)) then
   ! type: float, dim: [dim_seg, dim_mesh, dim_ens]
   call pio_decomp(pioSystem,              & ! input: pio system descriptor
                   ncd_double,             & ! input: data type (pio_int, pio_real, pio_double, pio_char)
                   [nSeg,nMesh_kw,nEns],   & ! input: dimension length == global array size
                   ixRch(ix1:ix2),         & ! input:
                   iodesc_mesh_kw_double)
 end if

 if (onRoute(muskingumCunge)) then
   ! type: float, dim: [dim_seg, dim_mesh, dim_ens]
   call pio_decomp(pioSystem,              & ! input: pio system descriptor
                   ncd_double,             & ! input: data type (pio_int, pio_real, pio_double, pio_char)
                   [nSeg,nMesh_mc,nEns],   & ! input: dimension length == global array size
                   ixRch(ix1:ix2),         & ! input:
                   iodesc_mesh_mc_double)
 end if

 if (onRoute(diffusiveWave)) then
   ! type: float, dim: [dim_seg, dim_mesh, dim_ens]
   call pio_decomp(pioSystem,              & ! input: pio system descriptor
                   ncd_double,             & ! input: data type (pio_int, pio_real, pio_double, pio_char)
                   [nSeg,nMesh_dw,nEns],   & ! input: dimension length == global array size
                   ixRch(ix1:ix2),         & ! input:
                   iodesc_mesh_dw_double)
 end if

 end associate

 ! Finishing up definition -------
 call end_def(pioFileDescState, ierr, cmessage)
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 CONTAINS

  SUBROUTINE set_dim_len(ixDim, ierr, message1)
   ! populate state netCDF dimension size
   USE public_var, ONLY: MAXQPAR
   USE globalData, ONLY: nMolecule
   USE globalData, ONLY: FRAC_FUTURE     ! To get size of q future for basin IRF
   USE globalData, ONLY: nEns, nRch      ! number of ensembles and river reaches
   implicit none
   ! input
   integer(i4b), intent(in)   :: ixDim    ! ixDim
   ! output
   integer(i4b), intent(out)  :: ierr     ! error code
   character(*), intent(out)  :: message1 ! error message

   ierr=0; message1='set_dim_len/'

   select case(ixDim)
    case(ixStateDims%seg);     meta_stateDims(ixStateDims%seg)%dimLength     = nRch
    case(ixStateDims%ens);     meta_stateDims(ixStateDims%ens)%dimLength     = nEns
    case(ixStateDims%tbound);  meta_stateDims(ixStateDims%tbound)%dimLength  = 2
    case(ixStateDims%tdh);     meta_stateDims(ixStateDims%tdh)%dimLength     = size(FRAC_FUTURE)
    case(ixStateDims%tdh_irf); meta_stateDims(ixStateDims%tdh_irf)%dimLength = 20   !just temporarily
    case(ixStateDims%mol_kw);  meta_stateDims(ixStateDims%mol_kw)%dimLength  = nMolecule%KW_ROUTE
    case(ixStateDims%mol_mc);  meta_stateDims(ixStateDims%mol_mc)%dimLength  = nMolecule%MC_ROUTE
    case(ixStateDims%mol_dw);  meta_stateDims(ixStateDims%mol_dw)%dimLength  = nMolecule%DW_ROUTE
    case(ixStateDims%wave);    meta_stateDims(ixStateDims%wave)%dimLength    = MAXQPAR
    case default; ierr=20; message1=trim(message1)//'unable to identify dimension variable index'; return
   end select

  END SUBROUTINE set_dim_len


  SUBROUTINE define_basinQ_state(ierr, message1)
   implicit none
   ! output
   integer(i4b), intent(out)         :: ierr          ! error code
   character(*), intent(out)         :: message1      ! error message
   ! local
   integer(i4b)                      :: iVar, ixDim   ! index loop
   integer(i4b)                      :: nDims         ! number of dimensions
   integer(i4b),allocatable          :: dim_basinQ(:) ! dimension id array

   ierr=0; message1='define_basinQ_state/'

   do iVar=1,nVarsBasinQ

     nDims = size(meta_basinQ(iVar)%varDim)
     if (allocated(dim_basinQ)) then
       deallocate(dim_basinQ)
     end if
     allocate(dim_basinQ(nDims))
     do ixDim = 1, nDims
       dim_basinQ(ixDim) = meta_stateDims(meta_basinQ(iVar)%varDim(ixDim))%dimId
     end do

     call def_var(pioFileDescState, meta_basinQ(iVar)%varName, meta_basinQ(iVar)%varType, ierr, cmessage, &
                  pioDimId=dim_basinQ, vdesc=meta_basinQ(iVar)%varDesc, vunit=meta_basinQ(iVar)%varUnit)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

   end do

  END SUBROUTINE define_basinQ_state


  SUBROUTINE define_IRFbas_state(ierr, message1)
   implicit none
   ! output
   integer(i4b), intent(out)         :: ierr          ! error code
   character(*), intent(out)         :: message1      ! error message
   ! local
   integer(i4b)                      :: iVar, ixDim   ! index loop
   integer(i4b)                      :: nDims         ! number of dimensions
   integer(i4b),allocatable          :: dim_IRFbas(:) ! dimension id array

   ierr=0; message1='define_IRFbas_state/'

   ! Check dimension length is populated
   if (meta_stateDims(ixStateDims%tdh)%dimLength == integerMissing) then
     call set_dim_len(ixStateDims%tdh, ierr, cmessage)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage)//' for '//trim(meta_stateDims(ixStateDims%tdh)%dimName); return; endif
   end if

   call def_dim(pioFileDescState, meta_stateDims(ixStateDims%tdh)%dimName, meta_stateDims(ixStateDims%tdh)%dimLength, meta_stateDims(ixStateDims%tdh)%dimId)
   if(ierr/=0)then; ierr=20; message1=trim(message1)//'cannot define dimension'; return; endif

   do iVar=1,nVarsIRFbas

     nDims = size(meta_irf_bas(iVar)%varDim)
     if (allocated(dim_IRFbas)) then
       deallocate(dim_IRFbas)
     end if
     allocate(dim_IRFbas(nDims))
     do ixDim = 1, nDims
       dim_IRFbas(ixDim) = meta_stateDims(meta_irf_bas(iVar)%varDim(ixDim))%dimId
     end do

     call def_var(pioFileDescState, meta_irf_bas(iVar)%varName, meta_irf_bas(iVar)%varType, ierr, cmessage, &
                  pioDimId=dim_IRFbas, vdesc=meta_irf_bas(iVar)%varDesc, vunit=meta_irf_bas(iVar)%varUnit)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

   end do

  END SUBROUTINE define_IRFbas_state

  SUBROUTINE define_IRF_state(ierr, message1)
   implicit none
   ! output
   integer(i4b), intent(out)         :: ierr        ! error code
   character(*), intent(out)         :: message1    ! error message
   ! local
   integer(i4b)                      :: iVar,ixDim  ! index loop for variables
   integer(i4b)                      :: nDims       ! number of dimensions
   integer(i4b),allocatable          :: dim_set(:)  ! dimensions combination case 4

   ierr=0; message1='define_IRF_state/'

   ! Define dimension needed for this routing specific state variables
   if (meta_stateDims(ixStateDims%tdh_irf)%dimLength == integerMissing) then
     call set_dim_len(ixStateDims%tdh_irf, ierr, cmessage)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage)//' for '//trim(meta_stateDims(ixStateDims%tdh_irf)%dimName); return; endif
   endif

   call def_dim(pioFileDescState, meta_stateDims(ixStateDims%tdh_irf)%dimName, meta_stateDims(ixStateDims%tdh_irf)%dimLength, meta_stateDims(ixStateDims%tdh_irf)%dimId)
   if(ierr/=0)then; ierr=20; message1=trim(message1)//'cannot define dimension'; return; endif

   associate(dim_seg     => meta_stateDims(ixStateDims%seg)%dimId,     &
             dim_ens     => meta_stateDims(ixStateDims%ens)%dimId,     &
             dim_tdh_irf => meta_stateDims(ixStateDims%tdh_irf)%dimId)

   call def_var(pioFileDescState, 'numQF', ncd_int, ierr, cmessage, pioDimId=[dim_seg,dim_ens], vdesc='number of future q time steps in a reach', vunit='-')
   if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

   do iVar=1,nVarsIRF
     nDims = size(meta_irf(iVar)%varDim)
     if (allocated(dim_set)) deallocate(dim_set)
     allocate(dim_set(nDims))
     do ixDim = 1, nDims
       dim_set(ixDim) = meta_stateDims(meta_irf(iVar)%varDim(ixDim))%dimId
     end do

     call def_var(pioFileDescState, meta_irf(iVar)%varName, meta_irf(iVar)%varType, ierr, cmessage, &
                  pioDimId=dim_set, vdesc=meta_irf(iVar)%varDesc, vunit=meta_irf(iVar)%varUnit)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
   end do

   end associate

  END SUBROUTINE define_IRF_state

  SUBROUTINE define_KWT_state(ierr, message1)
   implicit none
   ! output
   integer(i4b), intent(out)         :: ierr        ! error code
   character(*), intent(out)         :: message1    ! error message
   ! local
   integer(i4b)                      :: iVar,ixDim  ! index loop for variables
   integer(i4b)                      :: nDims       ! number of dimensions
   integer(i4b),allocatable          :: dim_set(:)  ! dimensions ID array

   ierr=0; message1='define_KWT_state/'

   ! Check dimension length is populated
   if (meta_stateDims(ixStateDims%wave)%dimLength == integerMissing) then
     call set_dim_len(ixStateDims%wave, ierr, cmessage)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage)//' for '//trim(meta_stateDims(ixStateDims%wave)%dimName); return; endif
   end if

   ! Define dimension needed for this routing specific state variables
   call def_dim(pioFileDescState, meta_stateDims(ixStateDims%wave)%dimName, meta_stateDims(ixStateDims%wave)%dimLength, meta_stateDims(ixStateDims%wave)%dimId)
   if(ierr/=0)then; ierr=20; message1=trim(message1)//'cannot define dimension'; return; endif

   associate(dim_seg     => meta_stateDims(ixStateDims%seg)%dimId,     &
             dim_ens     => meta_stateDims(ixStateDims%ens)%dimId,     &
             dim_wave    => meta_stateDims(ixStateDims%wave)%dimId)

   call def_var(pioFileDescState, 'numWaves', ncd_int, ierr, cmessage, pioDimId=[dim_seg,dim_ens], vdesc='number of waves in a reach', vunit='-')
   if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

   do iVar=1,nVarsKWT
     nDims = size(meta_kwt(iVar)%varDim)
     if (allocated(dim_set)) deallocate(dim_set)
     allocate(dim_set(nDims))
     do ixDim = 1, nDims
       dim_set(ixDim) = meta_stateDims(meta_kwt(iVar)%varDim(ixDim))%dimId
     end do

     call def_var(pioFileDescState, meta_kwt(iVar)%varName, meta_kwt(iVar)%varType, ierr, cmessage, &
                  pioDimId=dim_set, vdesc=meta_kwt(iVar)%varDesc, vunit=meta_kwt(iVar)%varUnit)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
   end do

   end associate

  END SUBROUTINE define_KWT_state

  SUBROUTINE define_KW_state(ierr, message1)
   implicit none
   ! output
   integer(i4b), intent(out)         :: ierr          ! error code
   character(*), intent(out)         :: message1      ! error message
   ! local
   integer(i4b)                      :: iVar,ixDim    ! index loop for variables
   integer(i4b)                      :: nDims         ! number of dimensions
   integer(i4b),allocatable          :: dim_set(:)    ! dimension Id array

   ierr=0; message1='define_KW_state/'

   ! Check dimension length is populated
   if (meta_stateDims(ixStateDims%mol_kw)%dimLength == integerMissing) then
     call set_dim_len(ixStateDims%mol_kw, ierr, cmessage)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage)//' for '//trim(meta_stateDims(ixStateDims%mol_kw)%dimName); return; endif
   end if

   call def_dim(pioFileDescState, meta_stateDims(ixStateDims%mol_kw)%dimName, meta_stateDims(ixStateDims%mol_kw)%dimLength, meta_stateDims(ixStateDims%mol_kw)%dimId)
   if(ierr/=0)then; ierr=20; message1=trim(message1)//'cannot define dimension'; return; endif

   do iVar=1,nVarsKW
     nDims = size(meta_KW(iVar)%varDim)
     if (allocated(dim_set)) deallocate(dim_set)
     allocate(dim_set(nDims))

     do ixDim = 1, nDims
       dim_set(ixDim) = meta_stateDims(meta_KW(iVar)%varDim(ixDim))%dimId
     end do

     call def_var(pioFileDescState, meta_KW(iVar)%varName, meta_KW(iVar)%varType, ierr, cmessage, &
                  pioDimId=dim_set, vdesc=meta_KW(iVar)%varDesc, vunit=meta_KW(iVar)%varUnit)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
   end do

  END SUBROUTINE define_KW_state

  SUBROUTINE define_MC_state(ierr, message1)
   implicit none
   ! output
   integer(i4b), intent(out)         :: ierr          ! error code
   character(*), intent(out)         :: message1      ! error message
   ! local
   integer(i4b)                      :: iVar,ixDim    ! index loop for variables
   integer(i4b)                      :: nDims         ! number of dimensions
   integer(i4b),allocatable          :: dim_set(:)    ! dimension Id array

   ierr=0; message1='define_MC_state/'

   ! Check dimension length is populated
   if (meta_stateDims(ixStateDims%mol_mc)%dimLength == integerMissing) then
     call set_dim_len(ixStateDims%mol_mc, ierr, cmessage)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage)//' for '//trim(meta_stateDims(ixStateDims%mol_mc)%dimName); return; endif
   end if

   call def_dim(pioFileDescState, meta_stateDims(ixStateDims%mol_mc)%dimName, meta_stateDims(ixStateDims%mol_mc)%dimLength, meta_stateDims(ixStateDims%mol_mc)%dimId)
   if(ierr/=0)then; ierr=20; message1=trim(message1)//'cannot define dimension'; return; endif

   do iVar=1,nVarsMC
     nDims = size(meta_mc(iVar)%varDim)
     if (allocated(dim_set)) deallocate(dim_set)
     allocate(dim_set(nDims))

     do ixDim = 1, nDims
       dim_set(ixDim) = meta_stateDims(meta_mc(iVar)%varDim(ixDim))%dimId
     end do

     call def_var(pioFileDescState, meta_mc(iVar)%varName, meta_mc(iVar)%varType, ierr, cmessage, &
                  pioDimId=dim_set, vdesc=meta_mc(iVar)%varDesc, vunit=meta_mc(iVar)%varUnit)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
   end do

  END SUBROUTINE define_MC_state

  SUBROUTINE define_DW_state(ierr, message1)
   implicit none
   ! output
   integer(i4b), intent(out)         :: ierr          ! error code
   character(*), intent(out)         :: message1      ! error message
   ! local
   integer(i4b)                      :: iVar,ixDim    ! index loop for variables
   integer(i4b)                      :: nDims         ! number of dimensions
   integer(i4b),allocatable          :: dim_set(:)    ! dimension Id array

   ierr=0; message1='define_DW_state/'

   ! Check dimension length is populated
   if (meta_stateDims(ixStateDims%mol_dw)%dimLength == integerMissing) then
     call set_dim_len(ixStateDims%mol_dw, ierr, cmessage)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage)//' for '//trim(meta_stateDims(ixStateDims%mol_dw)%dimName); return; endif
   end if

   call def_dim(pioFileDescState, meta_stateDims(ixStateDims%mol_dw)%dimName, meta_stateDims(ixStateDims%mol_dw)%dimLength, meta_stateDims(ixStateDims%mol_dw)%dimId)
   if(ierr/=0)then; ierr=20; message1=trim(message1)//'cannot define dimension'; return; endif

   do iVar=1,nVarsDW
     nDims = size(meta_dw(iVar)%varDim)
     if (allocated(dim_set)) deallocate(dim_set)
     allocate(dim_set(nDims))

     do ixDim = 1, nDims
       dim_set(ixDim) = meta_stateDims(meta_dw(iVar)%varDim(ixDim))%dimId
     end do

     call def_var(pioFileDescState, meta_dw(iVar)%varName, meta_dw(iVar)%varType, ierr, cmessage, &
                  pioDimId=dim_set, vdesc=meta_dw(iVar)%varDesc, vunit=meta_dw(iVar)%varUnit)
     if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
   end do

  END SUBROUTINE define_DW_state

 END SUBROUTINE define_state_nc


 ! *********************************************************************
 ! public subroutine: writing routing state NetCDF file
 ! *********************************************************************
 SUBROUTINE write_state_nc(fname,                &   ! Input: state netcdf name
                           ierr, message)            ! Output: error control

 USE public_var, ONLY: time_units             ! time units (seconds, hours, or days)
 USE public_var, ONLY: dt                     ! model time step size [sec]
 USE public_var, ONLY: doesBasinRoute
 USE public_var, ONLY: impulseResponseFunc
 USE public_var, ONLY: kinematicWaveTracking
 USE public_var, ONLY: kinematicWave
 USE public_var, ONLY: muskingumCunge
 USE public_var, ONLY: diffusiveWave
 USE globalData, ONLY: onRoute               ! logical to indicate which routing method(s) is on
 USE globalData, ONLY: RCHFLX_trib         ! tributary reach fluxes (ensembles, reaches)
 USE globalData, ONLY: NETOPO_main         ! mainstem reach topology
 USE globalData, ONLY: NETOPO_trib         ! tributary reach topology
 USE globalData, ONLY: RCHSTA_trib         ! tributary reach state (ensembles, reaches)
 USE globalData, ONLY: rch_per_proc        ! number of reaches assigned to each proc (size = num of procs+1)
 USE globalData, ONLY: nRch_mainstem       ! number of mainstem reaches
 USE globalData, ONLY: nTribOutlet         !
 USE globalData, ONLY: reachID             ! reach ID in network
 USE globalData, ONLY: nNodes              ! number of MPI tasks
 USE globalData, ONLY: nRch                ! number of reaches in network
 USE globalData, ONLY: TSEC                ! beginning/ending of simulation time step [sec]
 USE globalData, ONLY: timeVar             ! time variables (unit given by runoff data)

 implicit none

 ! input variables
 character(*),  intent(in)       :: fname             ! filename
 ! output variables
 integer(i4b), intent(out)       :: ierr              ! error code
 character(*), intent(out)       :: message           ! error message
 ! local variables
 real(dp)                        :: secPerTime        ! number of sec per time-unit. time-unit is from t_unit
 real(dp)                        :: restartTimeVar    ! restart timeVar [time_units]
 real(dp)                        :: tb_array(2)       ! restart timeVar [time_units]
 integer(i4b)                    :: iens              ! temporal
 integer(i4b)                    :: nRch_local        ! number of reach in each processors
 integer(i4b)                    :: nRch_root         ! number of reaches in root processors (including halo reaches)
 type(STRFLX), allocatable       :: RCHFLX_local(:)   ! reordered reach flux data structure
 type(RCHTOPO),allocatable       :: NETOPO_local(:)   ! reordered topology data structure
 type(STRSTA), allocatable       :: RCHSTA_local(:)   ! reordered statedata structure
 logical(lgt)                    :: restartOpen       ! logical to indicate restart file is open
 character(len=strLen)           :: t_unit            ! unit of time
 character(len=strLen)           :: cmessage          ! error message of downwind routine

 ierr=0; message='write_state_nc/'

 iens = 1

 if (masterproc) then
   nRch_local = nRch_mainstem+rch_per_proc(0)
   nRch_root = nRch_mainstem+nTribOutlet+rch_per_proc(0)
   allocate(RCHFLX_local(nRch_local), &
            NETOPO_local(nRch_local), &
            RCHSTA_local(nRch_local), stat=ierr, errmsg=cmessage)
   if (nRch_mainstem>0) then
     RCHFLX_local(1:nRch_mainstem) = RCHFLX_trib(iens,1:nRch_mainstem)
     NETOPO_local(1:nRch_mainstem) = NETOPO_main(1:nRch_mainstem)
     RCHSTA_local(1:nRch_mainstem) = RCHSTA_trib(iens,1:nRch_mainstem)
   end if
   if (rch_per_proc(0)>0) then
     RCHFLX_local(nRch_mainstem+1:nRch_local) = RCHFLX_trib(iens,nRch_mainstem+nTribOutlet+1:nRch_root)
     NETOPO_local(nRch_mainstem+1:nRch_local) = NETOPO_trib(:)
     RCHSTA_local(nRch_mainstem+1:nRch_local) = RCHSTA_trib(iens,nRch_mainstem+nTribOutlet+1:nRch_root)
   endif
 else
   nRch_local = rch_per_proc(pid)
   allocate(RCHFLX_local(nRch_local), &
            NETOPO_local(nRch_local), &
            RCHSTA_local(nRch_local),stat=ierr, errmsg=cmessage)
   RCHFLX_local = RCHFLX_trib(iens,:)
   NETOPO_local = NETOPO_trib(:)
   RCHSTA_local = RCHSTA_trib(iens,:)
 endif

 ! get the time multiplier needed to convert time to units of days
 t_unit =  time_units(1:index(time_units,' '))
 select case( trim(t_unit)  )
   case('seconds','second','sec','s'); secPerTime=1._dp
   case('minutes','minute','min');     secPerTime=60._dp
   case('hours','hour','hr','h');      secPerTime=3600._dp
   case('days','day','d');             secPerTime=86400._dp
   case default
     ierr=20; message=trim(message)//'<time_units>= '//trim(time_units)//': <time_units> must be seconds, minutes, hours or days.'; return
 end select

 restartTimeVar = timeVar + dt/secPerTime

 ! -- Write out to netCDF

 call openFile(pioSystem, pioFileDescState, trim(fname),pio_typename, ncd_write, restartOpen, ierr, cmessage)
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 call write_scalar_netcdf(pioFileDescState, 'nNodes', nNodes, ierr, cmessage)
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 call write_netcdf(pioFileDescState, 'reachID', reachID, [1], [nRch], ierr, cmessage)
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 call write_scalar_netcdf(pioFileDescState, 'restart_time', restartTimeVar, ierr, cmessage)
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 tb_array = [TSEC(0),TSEC(1)]
 call write_netcdf(pioFileDescState, 'time_bound', tb_array, [1], [2], ierr, cmessage)
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 call write_basinQ_state(ierr, cmessage)
 if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

 if (doesBasinRoute == 1) then
  call write_IRFbas_state(ierr, cmessage)
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 if (onRoute(impulseResponseFunc)) then
   call write_IRF_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 if (onRoute(kinematicWaveTracking)) then
   call write_KWT_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 if (onRoute(kinematicWave)) then
   call write_KW_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 if (onRoute(muskingumCunge)) then
   call write_MC_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 if (onRoute(diffusiveWave)) then
   call write_DW_state(ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
 end if

 ! clean decomposition data
 call freeDecomp(pioFileDescState, iodesc_state_double)
 call freeDecomp(pioFileDescState, iodesc_state_int)
 if (doesBasinRoute==1) then
   call freeDecomp(pioFileDescState, iodesc_irf_bas_double)
 end if
 if (onRoute(impulseResponseFunc))then
   call freeDecomp(pioFileDescState, iodesc_irf_double)
   call freeDecomp(pioFileDescState, iodesc_vol_double)
 end if
 if (onRoute(kinematicWaveTracking)) then
   call freeDecomp(pioFileDescState, iodesc_wave_int)
   call freeDecomp(pioFileDescState, iodesc_wave_double)
 end if
 if (onRoute(kinematicWave)) then
   call freeDecomp(pioFileDescState, iodesc_mesh_kw_double)
 end if
 if (onRoute(muskingumCunge)) then
   call freeDecomp(pioFileDescState, iodesc_mesh_mc_double)
 end if
 if (onRoute(diffusiveWave)) then
   call freeDecomp(pioFileDescState, iodesc_mesh_dw_double)
 end if

 call closeFile(pioFileDescState, restartOpen)

 CONTAINS

  SUBROUTINE write_basinQ_state(ierr, message1)
    implicit none
    ! output
    integer(i4b), intent(out)  :: ierr            ! error code
    character(*), intent(out)  :: message1        ! error message
    ! local variables
    type(states)               :: state           ! temporal state data structures -currently 2 river routing scheme + basin IRF routing
    integer(i4b)               :: iVar,iens,iSeg  ! index loops for variables, ensembles and segments respectively

    ! initialize error control
    ierr=0; message1='write_basinQ_state/'

    associate(nSeg     => size(RCHFLX_local),                         &
              nens     => meta_stateDims(ixStateDims%ens)%dimLength)

    allocate(state%var(nVarsBasinQ), stat=ierr, errmsg=cmessage)
    if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

    do iVar=1,nVarsBasinQ
      select case(iVar)
        case(ixBasinQ%q); allocate(state%var(iVar)%array_2d_dp(nSeg, nEns), stat=ierr)
        case default; ierr=20; message1=trim(message1)//'unable to identify basin routing variable index'; return
      end select
      if(ierr/=0)then; message1=trim(message1)//'problem allocating space for basin IRF routing state '//trim(meta_basinQ(iVar)%varName); return; endif
    end do

    ! --Convert data structures to arrays
    do iens=1,nens
      do iSeg=1,nSeg
        do iVar=1,nVarsBasinQ
          select case(iVar)
            case(ixBasinQ%q); state%var(iVar)%array_2d_dp(iSeg,iens) = RCHFLX_local(iSeg)%BASIN_QR(1)
            case default; ierr=20; message1=trim(message1)//'unable to identify basin IRF state variable index'; return
          end select
        enddo
      enddo
    enddo

    do iVar=1,nVarsBasinQ
      select case(iVar)
        case(ixBasinQ%q); call write_pnetcdf(pioFileDescState, meta_basinQ(iVar)%varName, state%var(iVar)%array_2d_dp, iodesc_state_double, ierr, cmessage)
        case default; ierr=20; message1=trim(message1)//'unable to identify reach inflow variable index for nc writing'; return
      end select
      if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
    end do

    end associate

  END SUBROUTINE write_basinQ_state

  SUBROUTINE write_IRFbas_state(ierr, message1)
    implicit none
    ! output
    integer(i4b), intent(out)  :: ierr            ! error code
    character(*), intent(out)  :: message1        ! error message
    ! local variables
    type(states)               :: state           ! temporal state data structures -currently 2 river routing scheme + basin IRF routing
    integer(i4b)               :: iVar,iens,iSeg  ! index loops for variables, ensembles and segments respectively

    ierr=0; message1='write_IRFbas_state/'

    associate(nSeg     => size(RCHFLX_local),                         &
              nEns     => meta_stateDims(ixStateDims%ens)%dimLength,  &
              ntdh     => meta_stateDims(ixStateDims%tdh)%dimLength)      ! maximum future q time steps among basins

    allocate(state%var(nVarsIRFbas), stat=ierr, errmsg=cmessage)
    if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

    do iVar=1,nVarsIRFbas

     select case(iVar)
      case(ixIRFbas%qfuture); allocate(state%var(iVar)%array_3d_dp(nSeg, ntdh, nEns), stat=ierr)
      case default; ierr=20; message1=trim(message1)//'unable to identify basin routing variable index'; return
     end select
     if(ierr/=0)then; message1=trim(message1)//'problem allocating space for basin IRF routing state '//trim(meta_irf_bas(iVar)%varName); return; endif

    end do

    ! --Convert data structures to arrays
    do iens=1,nEns
      do iSeg=1,nSeg
        do iVar=1,nVarsIRFbas
          select case(iVar)
            case(ixIRFbas%qfuture); state%var(iVar)%array_3d_dp(iSeg,:,iens) = RCHFLX_local(iSeg)%QFUTURE
            case default; ierr=20; message1=trim(message1)//'unable to identify basin IRF state variable index'; return
          end select
        enddo
      enddo
    enddo

    do iVar=1,nVarsIRFbas
      select case(iVar)
        case(ixIRFbas%qfuture); call write_pnetcdf(pioFileDescState, meta_irf_bas(iVar)%varName, state%var(iVar)%array_3d_dp, iodesc_irf_bas_double, ierr, cmessage)
        case default; ierr=20; message1=trim(message1)//'unable to identify basin IRF variable index for nc writing'; return
      end select
      if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
    enddo

    end associate

  END SUBROUTINE write_IRFbas_state

  SUBROUTINE write_IRF_state(ierr, message1)
    USE globalData, ONLY: idxIRF
    implicit none
    ! output
    integer(i4b), intent(out)  :: ierr            ! error code
    character(*), intent(out)  :: message1        ! error message
    ! local variables
    type(states)               :: state           ! temporal state data structures -currently 2 river routing scheme + basin IRF routing
    integer(i4b)               :: iVar,iens,iSeg  ! index loops for variables, ensembles and segments respectively
    integer(i4b), allocatable  :: numQF(:,:)      ! number of future Q time steps for each ensemble and segment

    ierr=0; message1='write_IRF_state/'

    associate(nSeg     => size(RCHFLX_local),                         &
              nEns     => meta_stateDims(ixStateDims%ens)%dimLength,  &
              nTbound  => meta_stateDims(ixStateDims%tbound)%dimLength, &
              ntdh_irf => meta_stateDims(ixStateDims%tdh_irf)%dimLength)    ! maximum future q time steps among reaches

    allocate(state%var(nVarsIRF), stat=ierr, errmsg=cmessage)
    if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

    ! array to store number of wave per segment and ensemble
    allocate(numQF(nEns,nSeg), stat=ierr)
    if(ierr/=0)then; message1=trim(message1)//'problem allocating space for numQF'; return; endif

    do iVar=1,nVarsIRF
      select case(iVar)
        case(ixIRF%qfuture); allocate(state%var(iVar)%array_3d_dp(nSeg, ntdh_irf, nEns), stat=ierr)
        case(ixIRF%vol);     allocate(state%var(iVar)%array_3d_dp(nSeg, nTbound, nEns), stat=ierr)
        case default; ierr=20; message1=trim(message1)//'unable to identify variable index'; return
      end select
      if(ierr/=0)then; message1=trim(message1)//'problem allocating space for IRF routing state '//trim(meta_irf(iVar)%varName); return; endif
    end do

    ! --Convert data structures to arrays
    do iens=1,nEns
      do iSeg=1,nSeg
        numQF(iens,iseg) = size(NETOPO_local(iSeg)%UH)
        do iVar=1,nVarsIRF
          select case(iVar)
            case(ixIRF%qfuture)
              state%var(iVar)%array_3d_dp(iSeg,1:numQF(iens,iSeg),iens) = RCHFLX_local(iSeg)%QFUTURE_IRF
              state%var(iVar)%array_3d_dp(iSeg,numQF(iens,iSeg)+1:ntdh_irf,iens) = realMissing
            case(ixIRF%vol)
              state%var(iVar)%array_3d_dp(iSeg,1:nTbound,iens) = RCHFLX_local(iSeg)%ROUTE(idxIRF)%REACH_VOL(0:1)
            case default; ierr=20; message1=trim(message1)//'unable to identify variable index'; return
          end select
        enddo ! variable loop
      enddo ! seg loop
    enddo ! ensemble loop

    ! writing netcdf
    call write_pnetcdf(pioFileDescState, 'numQF', numQF, iodesc_state_int, ierr, cmessage)
    if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

    do iVar=1,nVarsIRF
      select case(iVar)
        case(ixIRF%qfuture)
          call write_pnetcdf(pioFileDescState, meta_irf(iVar)%varName, state%var(iVar)%array_3d_dp, iodesc_irf_double, ierr, cmessage)
        case(ixIRF%vol)
          call write_pnetcdf(pioFileDescState, meta_irf(iVar)%varName, state%var(iVar)%array_3d_dp, iodesc_vol_double, ierr, cmessage)
        case default; ierr=20; message1=trim(message1)//'unable to identify IRF variable index for nc writing'; return
        if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
      end select
    end do

    end associate

  END SUBROUTINE write_IRF_state

  SUBROUTINE write_KWT_state(ierr, message1)
  USE globalData, ONLY: idxKWT
  implicit none
  ! output
  integer(i4b), intent(out)  :: ierr            ! error code
  character(*), intent(out)  :: message1        ! error message
  ! local variables
  type(states)               :: state           ! temporal state data structures -currently 2 river routing scheme + basin IRF routing
  integer(i4b)               :: iVar,iens,iSeg  ! index loops for variables, ensembles and segments respectively
  integer(i4b), allocatable  :: RFvec(:)        ! temporal vector
  integer(i4b), allocatable  :: numWaves(:,:)   ! number of waves for each ensemble and segment

  ierr=0; message1='write_KWT_state/'

  associate(nSeg     => size(RCHFLX_local),                         &
            nEns     => meta_stateDims(ixStateDims%ens)%dimLength,  &
            nWave    => meta_stateDims(ixStateDims%wave)%dimLength)     ! maximum waves allowed in a reach

  allocate(state%var(nVarsKWT), stat=ierr, errmsg=cmessage)
  if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

  ! array to store number of wave per segment and ensemble
  allocate(numWaves(nEns,nSeg), stat=ierr, errmsg=cmessage)
  if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

  do iVar=1,nVarsKWT
    select case(iVar)
      case(ixKWT%routed); allocate(state%var(iVar)%array_3d_int(nSeg, nWave, nEns), stat=ierr)
      case(ixKWT%tentry, ixKWT%texit, ixKWT%qwave, ixKWT%qwave_mod)
        allocate(state%var(iVar)%array_3d_dp(nSeg, nWave, nEns), stat=ierr)
      case(ixKWT%vol);   allocate(state%var(iVar)%array_2d_dp(nSeg, nEns), stat=ierr)
      case default; ierr=20; message1=trim(message1)//'unable to identify variable index'; return
    end select
    if(ierr/=0)then; message1=trim(message1)//'problem allocating space for KWT routing state '//trim(meta_kwt(iVar)%varName); return; endif
  end do

  ! --Convert data structures to arrays
  do iens=1,nEns
    do iSeg=1,nSeg
      numWaves(iens,iseg) = size(RCHSTA_local(iseg)%LKW_ROUTE%KWAVE)
      do iVar=1,nVarsKWT
        select case(iVar)
          case(ixKWT%tentry)
            state%var(iVar)%array_3d_dp(iSeg,1:numWaves(iens,iSeg),iens) = RCHSTA_local(iSeg)%LKW_ROUTE%KWAVE(:)%TI
            state%var(iVar)%array_3d_dp(iSeg,numWaves(iens,iSeg)+1:,iens) = realMissing
          case(ixKWT%texit)
            state%var(iVar)%array_3d_dp(iSeg,1:numWaves(iens,iSeg),iens) = RCHSTA_local(iSeg)%LKW_ROUTE%KWAVE(:)%TR
            state%var(iVar)%array_3d_dp(iSeg,numWaves(iens,iSeg)+1:,iens) = realMissing
          case(ixKWT%qwave)
            state%var(iVar)%array_3d_dp(iSeg,1:numWaves(iens,iSeg),iens) = RCHSTA_local(iSeg)%LKW_ROUTE%KWAVE(:)%QF
            state%var(iVar)%array_3d_dp(iSeg,numWaves(iens,iSeg)+1:,iens) = realMissing
          case(ixKWT%qwave_mod)
            state%var(iVar)%array_3d_dp(iSeg,1:numWaves(iens,iSeg),iens) = RCHSTA_local(iSeg)%LKW_ROUTE%KWAVE(:)%QM
            state%var(iVar)%array_3d_dp(iSeg,numWaves(iens,iSeg)+1:,iens) = realMissing
          case(ixKWT%routed) ! this is suppposed to be logical variable, but put it as 0 or 1 in double now
            if (allocated(RFvec)) deallocate(RFvec, stat=ierr)
            allocate(RFvec(numWaves(iens,iSeg)),stat=ierr); RFvec=0_i4b
            where (RCHSTA_local(iSeg)%LKW_ROUTE%KWAVE(:)%RF) RFvec=1_i4b
            state%var(iVar)%array_3d_int(iSeg,1:numWaves(iens,iSeg),iens) = RFvec
            state%var(iVar)%array_3d_int(iSeg,numWaves(iens,iSeg)+1:,iens) = integerMissing
          case(ixKWT%vol);  state%var(iVar)%array_2d_dp(iSeg,iens) = RCHFLX_local(iSeg)%ROUTE(idxKWT)%REACH_VOL(1)
          case default; ierr=20; message1=trim(message1)//'unable to identify KWT routing state variable index'; return
        end select
      enddo ! variable loop
    enddo ! seg loop
  enddo ! ensemble loop

  ! Writing netCDF
  call write_pnetcdf(pioFileDescState,'numWaves', numWaves, iodesc_state_int, ierr, cmessage)
  if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

  do iVar=1,nVarsKWT
    select case(iVar)
      case(ixKWT%routed)
        call write_pnetcdf(pioFileDescState, meta_kwt(iVar)%varName, state%var(iVar)%array_3d_int, iodesc_wave_int, ierr, cmessage)
      case(ixKWT%tentry, ixKWT%texit, ixKWT%qwave, ixKWT%qwave_mod)
        call write_pnetcdf(pioFileDescState, meta_kwt(iVar)%varName, state%var(iVar)%array_3d_dp, iodesc_wave_double, ierr, cmessage)
      case(ixKWT%vol)
        call write_pnetcdf(pioFileDescState, meta_kwt(iVar)%varName, state%var(iVar)%array_2d_dp, iodesc_state_double, ierr, cmessage)
      case default; ierr=20; message1=trim(message1)//'unable to identify KWT variable index for nc writing'; return
    end select
    if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
  end do

  end associate

  END SUBROUTINE write_KWT_state

  SUBROUTINE write_KW_state(ierr, message1)
    USE globalData, ONLY: idxKW
    implicit none
    ! output
    integer(i4b), intent(out)  :: ierr            ! error code
    character(*), intent(out)  :: message1        ! error message
    ! local variables
    type(states)               :: state           ! temporal state data structures -currently 2 river routing scheme + basin IRF routing
    integer(i4b)               :: iVar,iens,iSeg  ! index loops for variables, ensembles and segments respectively

    ierr=0; message1='write_KW_state/'

    associate(nSeg     => size(RCHFLX_local),                         &
              nEns     => meta_stateDims(ixStateDims%ens)%dimLength,  &
              nMesh    => meta_stateDims(ixStateDims%mol_kw)%dimLength)     ! maximum waves allowed in a reach

    allocate(state%var(nVarsKW), stat=ierr, errmsg=cmessage)
    if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

    do iVar=1,nVarsKW
      select case(iVar)
       case(ixKW%qsub); allocate(state%var(iVar)%array_3d_dp(nSeg, nMesh, nEns), stat=ierr)
       case(ixKW%vol);  allocate(state%var(iVar)%array_2d_dp(nSeg, nEns), stat=ierr)
       case default; ierr=20; message1=trim(message1)//'unable to identify variable index'; return
      end select
      if(ierr/=0)then; message1=trim(message1)//'problem allocating space for KW routing state '//trim(meta_kw(iVar)%varName); return; endif
    end do

    ! --Convert data structures to arrays
    do iens=1,nEns
      do iSeg=1,nSeg
        do iVar=1,nVarsKW
          select case(iVar)
            case(ixKW%qsub); state%var(iVar)%array_3d_dp(iSeg,1:nMesh,iens) = RCHSTA_local(iSeg)%KW_ROUTE%molecule%Q(1:nMesh)
            case(ixKW%vol);  state%var(iVar)%array_2d_dp(iSeg,iens) = RCHFLX_local(iSeg)%ROUTE(idxKW)%REACH_VOL(1)
            case default; ierr=20; message1=trim(message1)//'unable to identify KW routing state variable index'; return
          end select
        enddo ! variable loop
      enddo ! seg loop
    enddo ! ensemble loop

    ! Writing netCDF
    do iVar=1,nVarsKW
      select case(iVar)
       case(ixKW%qsub)
         call write_pnetcdf(pioFileDescState, meta_kw(iVar)%varName, state%var(iVar)%array_3d_dp, iodesc_mesh_kw_double, ierr, cmessage)
       case(ixKW%vol)
         call write_pnetcdf(pioFileDescState, meta_kw(iVar)%varName, state%var(iVar)%array_2d_dp, iodesc_state_double, ierr, cmessage)
       case default; ierr=20; message1=trim(message1)//'unable to identify KW variable index for nc writing'; return
      end select
      if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
    end do

    end associate

  END SUBROUTINE write_KW_state

  SUBROUTINE write_MC_state(ierr, message1)
    USE globalData, ONLY: idxMC
    implicit none
    ! output
    integer(i4b), intent(out)  :: ierr            ! error code
    character(*), intent(out)  :: message1        ! error message
    ! local variables
    type(states)               :: state           ! temporal state data structures -currently 2 river routing scheme + basin IRF routing
    integer(i4b)               :: iVar,iens,iSeg  ! index loops for variables, ensembles and segments respectively

    ierr=0; message1='write_MC_state/'

    associate(nSeg     => size(RCHFLX_local),                         &
              nEns     => meta_stateDims(ixStateDims%ens)%dimLength,  &
              nMesh    => meta_stateDims(ixStateDims%mol_mc)%dimLength)     ! maximum waves allowed in a reach

    allocate(state%var(nVarsMC), stat=ierr, errmsg=cmessage)
    if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

    do iVar=1,nVarsMC
      select case(iVar)
        case(ixMC%qsub); allocate(state%var(iVar)%array_3d_dp(nSeg, nMesh, nEns), stat=ierr)
        case(ixMC%vol);  allocate(state%var(iVar)%array_2d_dp(nSeg, nEns), stat=ierr)
        case default; ierr=20; message1=trim(message1)//'unable to identify variable index'; return
      end select
      if(ierr/=0)then; message1=trim(message1)//'problem allocating space for MC routing state '//trim(meta_mc(iVar)%varName); return; endif
    end do

    ! --Convert data structures to arrays
    do iens=1,nEns
      do iSeg=1,nSeg
        do iVar=1,nVarsMC
          select case(iVar)
            case(ixMC%qsub); state%var(iVar)%array_3d_dp(iSeg,1:nMesh,iens) = RCHSTA_local(iSeg)%MC_ROUTE%molecule%Q(1:nMesh)
            case(ixMC%vol);  state%var(iVar)%array_2d_dp(iSeg,iens) = RCHFLX_local(iSeg)%ROUTE(idxMC)%REACH_VOL(1)
            case default; ierr=20; message1=trim(message1)//'unable to identify MC routing state variable index'; return
          end select
        enddo ! variable loop
      enddo ! seg loop
    enddo ! ensemble loop

    ! Writing netCDF
    do iVar=1,nVarsMC
      select case(iVar)
       case(ixMC%qsub)
         call write_pnetcdf(pioFileDescState, meta_mc(iVar)%varName, state%var(iVar)%array_3d_dp, iodesc_mesh_mc_double, ierr, cmessage)
       case(ixMC%vol)
         call write_pnetcdf(pioFileDescState, meta_mc(iVar)%varName, state%var(iVar)%array_2d_dp, iodesc_state_double, ierr, cmessage)
       case default; ierr=20; message1=trim(message1)//'unable to identify MC variable index for nc writing'; return
      end select
      if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
    end do

    end associate

  END SUBROUTINE write_MC_state

  SUBROUTINE write_DW_state(ierr, message1)
    USE globalData, ONLY: idxDW
    implicit none
    ! output
    integer(i4b), intent(out)  :: ierr            ! error code
    character(*), intent(out)  :: message1        ! error message
    ! local variables
    type(states)               :: state           ! temporal state data structures -currently 2 river routing scheme + basin IRF routing
    integer(i4b)               :: iVar,iens,iSeg  ! index loops for variables, ensembles and segments respectively

    ierr=0; message1='write_DW_state/'

    associate(nSeg     => size(RCHFLX_local),                         &
              nEns     => meta_stateDims(ixStateDims%ens)%dimLength,  &
              nMesh    => meta_stateDims(ixStateDims%mol_dw)%dimLength)     ! maximum waves allowed in a reach

    allocate(state%var(nVarsDW), stat=ierr, errmsg=cmessage)
    if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif

    do iVar=1,nVarsDW
      select case(iVar)
        case(ixDW%qsub); allocate(state%var(iVar)%array_3d_dp(nSeg, nMesh, nEns), stat=ierr)
        case(ixDW%vol);  allocate(state%var(iVar)%array_2d_dp(nSeg, nEns), stat=ierr)
       case default; ierr=20; message1=trim(message1)//'unable to identify variable index'; return
      end select
      if(ierr/=0)then; message1=trim(message1)//'problem allocating space for DW routing state '//trim(meta_dw(iVar)%varName); return; endif
    end do

    ! --Convert data structures to arrays
    do iens=1,nEns
      do iSeg=1,nSeg
        do iVar=1,nVarsDW
          select case(iVar)
            case(ixDW%qsub); state%var(iVar)%array_3d_dp(iSeg,1:nMesh,iens) = RCHSTA_local(iSeg)%DW_ROUTE%molecule%Q(1:nMesh)
            case(ixDW%vol);  state%var(iVar)%array_2d_dp(iSeg,iens) = RCHFLX_local(iSeg)%ROUTE(idxDW)%REACH_VOL(1)
            case default; ierr=20; message1=trim(message1)//'unable to identify DW routing state variable index'; return
          end select
        enddo ! variable loop
      enddo ! seg loop
    enddo ! ensemble loop

    ! Writing netCDF
    do iVar=1,nVarsDW
      select case(iVar)
       case(ixDW%qsub)
         call write_pnetcdf(pioFileDescState, meta_dw(iVar)%varName, state%var(iVar)%array_3d_dp, iodesc_mesh_dw_double, ierr, cmessage)
       case(ixDW%vol)
         call write_pnetcdf(pioFileDescState, meta_dw(iVar)%varName, state%var(iVar)%array_2d_dp, iodesc_state_double, ierr, cmessage)
       case default; ierr=20; message1=trim(message1)//'unable to identify DW variable index for nc writing'; return
      end select
      if(ierr/=0)then; message1=trim(message1)//trim(cmessage); return; endif
    end do

    end associate

  END SUBROUTINE write_DW_state


 END SUBROUTINE write_state_nc

END MODULE write_restart_pio
