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
 [DllImport("user32.dll")] static extern bool ReleaseCapture();
 [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h,int msg,IntPtr w,IntPtr l);
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
  // Applying ACCENT_ENABLE_BLURBEHIND to the main layered HWND paints a
  // rectangular tint outside WPF's rounded Border on some Windows 11 builds.
  // Keep the main HWND fully transparent and draw glass only inside RootGlass.
  BlurEnabled=false;
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
  IntPtr region=CreateRoundRectRgn(0,0,rect.right+1,rect.bottom+1,48,48);
  if(region!=IntPtr.Zero && SetWindowRgn(handle,region,true)==0)DeleteObject(region);
 }
 public void BeginResize(){ReleaseCapture();SendMessage(handle,0x00A1,new IntPtr(17),IntPtr.Zero);}
 public static void BlurPopup(IntPtr hwnd){
  // Native blur colors the popup's full rectangular HWND on some Windows 11
  // builds, leaving black corners around rounded menus and tooltips. Popup
  // templates already draw their own translucent glass, so keep HWND clear.
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
