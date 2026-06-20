package com.ax.app;
import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import androidx.fragment.app.Fragment;
import androidx.preference.PreferenceFragmentCompat;
public class HostActivity extends Activity {
  @Override
  protected void onCreate(Bundle b) {
    super.onCreate(b);
    String name = getIntent().getStringExtra("fragment_class");
    Fragment f = Fragment.instantiate(this, name, b);
  }
  public static class Prefs extends PreferenceFragmentCompat {
    public void onCreatePreferences(Bundle b, String s) {}
  }
}
