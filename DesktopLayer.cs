using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

// Keep the widget above its desktop owner, below normal apps, and never take focus.
public sealed class DesktopLayer {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
 [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] static extern IntPtr SetLong(IntPtr h, int index, IntPtr value);
 [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetLong(IntPtr h, int index);
 [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
 [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr h, ref CompositionData data);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
 [DllImport("gdi32.dll")] static extern IntPtr CreateRoundRectRgn(int left,int top,int right,int bottom,int ellipseWidth,int ellipseHeight);
 [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
 [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr h,IntPtr region,bool redraw);
 [StructLayout(LayoutKind.Sequential)] struct RECT { public int left,top,right,bottom; }
 [StructLayout(LayoutKind.Sequential)] struct Accent { public int state, flags, color, animation; }
 [StructLayout(LayoutKind.Sequential)] struct CompositionData { public int attribute; public IntPtr data; public int size; }
 [StructLayout(LayoutKind.Sequential)] struct WINDOWPOS { public IntPtr hwnd, after; public int x,y,cx,cy; public uint flags; }
 readonly HwndSource source;
 readonly IntPtr handle;
 public bool BlurEnabled {get; private set;}
 public DesktopLayer(Window window) {
  handle = new WindowInteropHelper(window).Handle;
  source = HwndSource.FromHwnd(handle);
  IntPtr desktop = FindWindow("Progman", null);
  if (desktop != IntPtr.Zero) SetLong(handle, -8, desktop);
  SetLong(handle, -20, new IntPtr(GetLong(handle,-20).ToInt64() | 0x08000000L | 0x80L));
  source.AddHook(Hook);
  Accent accent = new Accent {state=3,flags=0,color=unchecked((int)0x99F7F2EA)};
  IntPtr memory=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Accent)));
  try {
   Marshal.StructureToPtr(accent,memory,false);
   CompositionData data=new CompositionData {attribute=19,data=memory,size=Marshal.SizeOf(typeof(Accent))};
   BlurEnabled=SetWindowCompositionAttribute(handle,ref data)!=0;
  } catch (EntryPointNotFoundException) { BlurEnabled=false; }
  finally {Marshal.FreeHGlobal(memory);}
  Lower();
  ApplyRoundedRegion();
 }
 public bool IsCovered() {
  IntPtr front=GetForegroundWindow();
  RECT a,b;
  return front!=IntPtr.Zero && front!=handle && GetWindowRect(front,out a) && GetWindowRect(handle,out b) && a.left<=b.left && a.top<=b.top && a.right>=b.right && a.bottom>=b.bottom;
 }
 public void Lower() {
  IntPtr desktop=FindWindow("Progman",null);
  if(desktop!=IntPtr.Zero)SetLong(handle,-8,desktop);
  SetWindowPos(handle, new IntPtr(1),0,0,0,0,0x13);
  ApplyRoundedRegion();
 }
 public void ApplyRoundedRegion(){
  RECT rect;
  if(!GetClientRect(handle,out rect) || rect.right<=0 || rect.bottom<=0)return;
  IntPtr region=CreateRoundRectRgn(0,0,rect.right+1,rect.bottom+1,40,40);
  if(region!=IntPtr.Zero && SetWindowRgn(handle,region,true)==0)DeleteObject(region);
 }
 public static void BlurPopup(IntPtr hwnd){
  Accent accent=new Accent {state=3,flags=0,color=unchecked((int)0x99EEEFEF)};
  IntPtr p=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Accent)));
  try{Marshal.StructureToPtr(accent,p,false);CompositionData data=new CompositionData {attribute=19,data=p,size=Marshal.SizeOf(typeof(Accent))};SetWindowCompositionAttribute(hwnd,ref data);}catch(EntryPointNotFoundException){}finally{Marshal.FreeHGlobal(p);}
 }
 IntPtr Hook(IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled) {
  if (msg == 0x21) { handled=true; return new IntPtr(3); }
  if (msg == 0x0005) ApplyRoundedRegion();
  if (msg == 0x46 && l != IntPtr.Zero) {
   WINDOWPOS pos = (WINDOWPOS)Marshal.PtrToStructure(l,typeof(WINDOWPOS));
   if ((pos.flags & 4) == 0) { pos.after=new IntPtr(1); pos.flags |= 0x10; Marshal.StructureToPtr(pos,l,false); }
  }
  return IntPtr.Zero;
 }
}
