using System.ComponentModel;
using System.Globalization;
using System.Windows.Data;
using System.Windows.Markup;
using TokenTracker.Core.Localization;

namespace TokenTracker.Windows.Localization;

/// <summary>语言切换时通知所有 {l:Tr} 绑定刷新。</summary>
public sealed class TranslationSource : INotifyPropertyChanged
{
    public static TranslationSource Instance { get; } = new();

    TranslationSource() => L10n.LanguageChanged += () => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Version)));

    /// <summary>语言版本号：变化即触发绑定重新求值。</summary>
    public string Version => L10n.Language;

    public event PropertyChangedEventHandler? PropertyChanged;
}

sealed class TrConverter : IValueConverter
{
    public static TrConverter Instance { get; } = new();

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        L10n.T(parameter as string ?? "");

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

/// <summary>
/// XAML 文案：{l:Tr 概览}。键是中文原文（与 macOS 共享 Localizable.strings）；
/// 用转换器而不是索引器路径，避免键里的逗号/方括号被当作绑定语法。
/// </summary>
[MarkupExtensionReturnType(typeof(string))]
public sealed class TrExtension(string key) : MarkupExtension
{
    public string Key { get; set; } = key;

    public override object ProvideValue(IServiceProvider serviceProvider) =>
        new Binding(nameof(TranslationSource.Version))
        {
            Source = TranslationSource.Instance,
            Mode = BindingMode.OneWay,
            Converter = TrConverter.Instance,
            ConverterParameter = Key,
        }.ProvideValue(serviceProvider);
}
